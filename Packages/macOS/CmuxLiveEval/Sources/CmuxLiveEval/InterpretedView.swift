public import AppKit
import Observation

/// Native view hosting an interpreted program.
///
/// Each interpreted statement owns an Observation tracking scope. A state
/// mutation therefore rebuilds only the statement subtree that read the box.
@MainActor
public final class InterpretedView: NSView {
    public let engine: LiveEvalEngine
    public let store: LiveStateStore
    private var renderedView: NSView?

    public init(engine: LiveEvalEngine) {
        self.engine = engine
        store = engine.makeStore()
        super.init(frame: .zero)
        renderRoot()
    }

    /// Test and demo initializer with externally owned state storage.
    public init(engine: LiveEvalEngine, store: LiveStateStore) {
        self.engine = engine
        self.store = store
        super.init(frame: .zero)
        renderRoot()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: NSSize {
        renderedView?.fittingSize ?? .zero
    }

    private func renderRoot() {
        engine.traceRender(Self.self)
        let node = engine.evaluateRoot(LiveScope(store: store))
        install(LiveNodeRenderer.makeView(for: node, engine: engine, parentAxis: nil))
    }

    private func install(_ content: NSView) {
        renderedView?.removeFromSuperview()
        renderedView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        invalidateIntrinsicContentSize()
    }
}

@MainActor
private enum LiveNodeRenderer {
    static func makeView(
        for node: LiveNode,
        engine: LiveEvalEngine,
        parentAxis: LiveStackAxis?
    ) -> NSView {
        switch node {
        case .text(let string):
            let field = NSTextField(wrappingLabelWithString: string)
            field.maximumNumberOfLines = 0
            return field
        case .button(let title, let action):
            return LiveActionButton(title: title, action: action)
        case .textField(let placeholder, let binding):
            return LiveBoundTextField(placeholder: placeholder, binding: binding)
        case .toggle(let title, let binding):
            return LiveBoundToggle(title: title, binding: binding)
        case .stack(let axis, let spacing, let content):
            return makeBlockView(
                content,
                engine: engine,
                axis: axis,
                spacing: CGFloat(spacing ?? 8)
            )
        case .forEach(let rows):
            let stack = makeStack(axis: parentAxis ?? .vertical, spacing: 0)
            for row in rows {
                stack.addArrangedSubview(
                    makeBlockView(
                        row.content,
                        engine: engine,
                        axis: parentAxis ?? .vertical,
                        spacing: 0
                    )
                )
            }
            return stack
        case .spacer:
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            return spacer
        case .divider:
            let divider = NSBox()
            divider.boxType = .separator
            if parentAxis == .horizontal {
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
            } else {
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
            return divider
        case .empty:
            return LiveEmptyView()
        }
    }

    static func makeBlockView(
        _ block: LiveBlock,
        engine: LiveEvalEngine,
        axis: LiveStackAxis,
        spacing: CGFloat
    ) -> NSView {
        let entries = engine.expandBlock(block)
        if axis == .depth {
            let container = NSView()
            for entry in entries {
                let statement = LiveStatementView(
                    engine: engine,
                    entry: entry,
                    parentAxis: axis
                )
                statement.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(statement)
                NSLayoutConstraint.activate([
                    statement.topAnchor.constraint(equalTo: container.topAnchor),
                    statement.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    statement.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    statement.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
            return container
        }

        let stack = makeStack(axis: axis, spacing: spacing)
        for entry in entries {
            stack.addArrangedSubview(
                LiveStatementView(engine: engine, entry: entry, parentAxis: axis)
            )
        }
        return stack
    }

    private static func makeStack(axis: LiveStackAxis, spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = axis == .horizontal ? .horizontal : .vertical
        stack.alignment = axis == .horizontal ? .centerY : .leading
        stack.spacing = spacing
        return stack
    }
}

@MainActor
private final class LiveStatementView: NSView {
    private let engine: LiveEvalEngine
    private let entry: LiveBlockEntry
    private let parentAxis: LiveStackAxis
    private var renderedView: NSView?
    private var refreshTask: Task<Void, Never>?

    init(engine: LiveEvalEngine, entry: LiveBlockEntry, parentAxis: LiveStackAxis) {
        self.engine = engine
        self.entry = entry
        self.parentAxis = parentAxis
        super.init(frame: .zero)
        renderTracked()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTask?.cancel()
    }

    override var intrinsicContentSize: NSSize {
        renderedView?.fittingSize ?? .zero
    }

    private func renderTracked() {
        refreshTask?.cancel()
        refreshTask = nil
        engine.traceRender(Self.self)
        let nodes = withObservationTracking {
            engine.evaluateStatement(entry.statement, entry.scope)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        let content = makeContent(for: nodes)
        install(content)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.renderTracked()
        }
    }

    private func makeContent(for nodes: [LiveNode]) -> NSView {
        if nodes.count == 1, let node = nodes.first {
            return LiveNodeRenderer.makeView(for: node, engine: engine, parentAxis: parentAxis)
        }
        let stack = NSStackView()
        stack.orientation = parentAxis == .horizontal ? .horizontal : .vertical
        stack.alignment = parentAxis == .horizontal ? .centerY : .leading
        stack.spacing = 0
        for node in nodes {
            stack.addArrangedSubview(
                LiveNodeRenderer.makeView(for: node, engine: engine, parentAxis: parentAxis)
            )
        }
        return stack
    }

    private func install(_ content: NSView) {
        renderedView?.removeFromSuperview()
        renderedView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        invalidateIntrinsicContentSize()
    }
}

@MainActor
private final class LiveActionButton: NSButton {
    private let actionHandler: () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        actionHandler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(performAction(_:))
        bezelStyle = .rounded
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func performAction(_ sender: Any?) {
        actionHandler()
    }
}

@MainActor
private final class LiveBoundTextField: NSTextField, NSTextFieldDelegate {
    private let binding: LiveValueBinding<String>
    private var refreshTask: Task<Void, Never>?

    init(placeholder: String, binding: LiveValueBinding<String>) {
        self.binding = binding
        super.init(frame: .zero)
        placeholderString = placeholder
        delegate = self
        observeValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTask?.cancel()
    }

    func controlTextDidChange(_ notification: Notification) {
        binding.wrappedValue = stringValue
    }

    private func observeValue() {
        let value = withObservationTracking {
            binding.wrappedValue
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        if stringValue != value {
            stringValue = value
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.observeValue()
        }
    }
}

@MainActor
private final class LiveBoundToggle: NSButton {
    private let binding: LiveValueBinding<Bool>
    private var refreshTask: Task<Void, Never>?

    init(title: String, binding: LiveValueBinding<Bool>) {
        self.binding = binding
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        target = self
        action = #selector(toggleValue(_:))
        observeValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTask?.cancel()
    }

    @objc
    private func toggleValue(_ sender: Any?) {
        binding.wrappedValue = state == .on
    }

    private func observeValue() {
        let value = withObservationTracking {
            binding.wrappedValue
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        state = value ? .on : .off
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.observeValue()
        }
    }
}

@MainActor
private final class LiveEmptyView: NSView {
    override var intrinsicContentSize: NSSize { .zero }
}
