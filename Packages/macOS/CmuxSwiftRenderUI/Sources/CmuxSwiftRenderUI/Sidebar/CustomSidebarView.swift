import AppKit
import CmuxSwiftRender
import Observation

/// Native custom-sidebar surface backed by a hot-reloading model.
@MainActor
public final class CustomSidebarView: NSView {
    private let model: CustomSidebarModel
    private let dispatch: SidebarActionDispatch
    private var dataContext: [String: SwiftValue]
    private var contentInsets: CustomSidebarContentInsets
    private let contentView: CustomSidebarContentView
    private var presentationObserver: CustomSidebarPresentationObserver?
    private var renderTask: Task<Void, Never>?
    private var isStarted = false

    /// Creates a sidebar bound to a file, live data, and host action dispatch.
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero,
        interpreter: any SidebarInterpreting = InProcessSidebarInterpreter()
    ) {
        let model = CustomSidebarModel(fileURL: fileURL, interpreter: interpreter)
        self.model = model
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        contentView = CustomSidebarContentView(
            state: model.state,
            swiftRender: model.swiftRender,
            hasRenderedSwift: model.hasRenderedSwift,
            dispatch: dispatch,
            contentInsets: contentInsets
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        presentationObserver = CustomSidebarPresentationObserver(model: model) { [weak self] in
            self?.modelDidChange()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    /// Starts file observation and rendering. Idempotent.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        model.start()
        modelDidChange()
    }

    /// Stops all observation and in-flight rendering. Idempotent.
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        renderTask?.cancel()
        renderTask = nil
        model.stop()
    }

    /// Updates host-owned state without rebuilding the native view hierarchy.
    public func update(
        dataContext: [String: SwiftValue],
        contentInsets: CustomSidebarContentInsets
    ) {
        let dataChanged = self.dataContext != dataContext
        let insetsChanged = self.contentInsets != contentInsets
        self.dataContext = dataContext
        self.contentInsets = contentInsets
        if insetsChanged {
            refreshPresentation()
        }
        if dataChanged {
            scheduleRender()
        }
    }

    /// Returns interactive regions for hosts that forward pointer input.
    public func tapTargets() -> [SidebarTapTarget] {
        contentView.tapTargets()
    }

    private func modelDidChange() {
        refreshPresentation()
        scheduleRender()
    }

    private func refreshPresentation() {
        contentView.update(
            state: model.state,
            swiftRender: model.swiftRender,
            hasRenderedSwift: model.hasRenderedSwift,
            contentInsets: contentInsets
        )
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = nil
        guard isStarted, case .swiftSource = model.state else { return }
        let context = dataContext
        renderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.renderSwift(dataContext: context)
            guard !Task.isCancelled else { return }
            self.refreshPresentation()
        }
    }

    deinit {
        renderTask?.cancel()
    }
}

/// Bridges Observation into native view updates without polling or timers.
@MainActor
private final class CustomSidebarPresentationObserver {
    private weak var model: CustomSidebarModel?
    private let apply: @MainActor () -> Void
    private var observationTask: Task<Void, Never>?
    private var legacyGeneration: UInt64 = 0
    private var isCancelled = false

    init(model: CustomSidebarModel, apply: @MainActor @escaping () -> Void) {
        self.model = model
        self.apply = apply
        apply()

        if #available(macOS 26.0, *) {
            observationTask = Task { @MainActor [weak self, weak model] in
                guard let model else { return }
                let revisions = Observations { model.presentationRevision }
                for await _ in revisions {
                    guard !Task.isCancelled, let self, !self.isCancelled else { return }
                    self.apply()
                }
            }
        } else {
            armLegacyObservation()
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        legacyGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
    }

    private func armLegacyObservation() {
        guard !isCancelled, let model else { return }
        legacyGeneration &+= 1
        let generation = legacyGeneration
        withObservationTracking {
            _ = model.presentationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isCancelled,
                      self.legacyGeneration == generation
                else { return }
                self.apply()
                self.armLegacyObservation()
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }
}
