import AppKit
import CmuxNextActions
import CmuxNextDesign

extension InternalPageID {
    static let setupGuide = InternalPageID(rawValue: "setup-guide")
}

struct SetupGuideSection: Identifiable {
    let id: String
    let title: String
    let steps: [String]
    let action: (id: String, title: String)?
}

/// Offline instructions from setup::TASKS. Only a deliberate button click starts a shared action.
@MainActor
final class SetupGuidePage: InternalPageProvider {
    var page: InternalPageID { .setupGuide }
    var title: String { Self.pageTitle }
    var symbol: String { "book" }
    static var pageTitle: String { String(localized: "setupGuide.title", defaultValue: "Setup Guide", table: "SetupGuide", bundle: .module) }

    private weak var registry: ActionRegistry?

    init(registry: ActionRegistry) { self.registry = registry }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        SetupGuideView { [weak registry] action in
            // The manifest does not grant arbitrary native actions to the guide.
            guard action == "accounts.githubConnect" else { return }
            registry?.perform(ActionID(rawValue: action), invocation: ActionInvocation(origin: .user))
        }
    }

    static func bind(into registry: ActionRegistry, services: AppServices) {
        services.pages.register(SetupGuidePage(registry: registry))
        registry.bindEffect("help.setupGuide", effect: { [weak services] invocation in
            guard let services, services.pages.show(.setupGuide, in: services.windows.active, focus: invocation.allowsViewChange) != nil else {
                return .refused(RefusalStrings.noWindowOpen)
            }
            return .done
        })
    }
}

/// Selectable instructions with native scrolling; no credential reads or automatic actions.
final class SetupGuideView: NSView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView()
    private let document = Document()
    private var lines: [(view: NSView, gap: CGFloat)] = []
    private var actions: [ObjectIdentifier: String] = [:]
    private let onAction: (String) -> Void
    private let readingWidth: CGFloat

    init(sectionSpacing: CGFloat = Metrics.space5, readingWidth: CGFloat = 680, onAction: @escaping (String) -> Void = { _ in }) {
        self.readingWidth = readingWidth
        self.onAction = onAction
        super.init(frame: .zero)
        setAccessibilityIdentifier("setup-guide")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        SystemScrollers.followThin(scroll)
        scroll.documentView = document
        addSubview(scroll)
        add(SetupGuidePage.pageTitle, font: Typography.title, gap: 0, id: "setup-guide-title")
        for section in SetupGuideContent.sections {
            add(section.title, font: Typography.bodyEmphasized, gap: sectionSpacing, id: "setup-guide-\(section.id)")
            for (index, step) in section.steps.enumerated() {
                add("\(index + 1). \(step)", font: Typography.body, gap: Metrics.space3,
                    id: "setup-guide-\(section.id)-\(index)")
            }
            if let action = section.action {
                let button = ThemedBezelButton(title: action.title, target: self, action: #selector(performAction(_:)))
                button.font = Typography.body
                button.bezelStyle = .rounded
                button.cell?.wraps = true
                button.setAccessibilityIdentifier("setup-guide-\(section.id)-action")
                actions[ObjectIdentifier(button)] = action.id
                document.addSubview(button)
                lines.append((button, Metrics.space3))
            }
        }
    }

    @objc private func performAction(_ sender: NSButton) {
        guard let action = actions[ObjectIdentifier(sender)] else { return }
        onAction(action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func add(_ text: String, font: NSFont, gap: CGFloat, id: String) {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = font
        label.isSelectable = true
        label.focusRingType = .none
        label.setAccessibilityIdentifier(id)
        document.addSubview(label)
        lines.append((label, gap))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let available = scroll.contentSize.width
        let width = min(readingWidth, max(1, available - 2 * Metrics.space5))
        var y = Metrics.space5
        for (view, gap) in lines {
            y += gap
            let attributed = (view as? NSTextField)?.attributedStringValue ?? (view as? NSButton)?.attributedTitle ?? NSAttributedString(string: "")
            let isButton = view is NSButton
            let textWidth = max(1, width - (isButton ? 2 * Metrics.space3 : 0))
            let height = ceil(attributed.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
            let rowHeight = isButton ? max(Metrics.controlHeight, height + Metrics.space2) : height
            let rowWidth = isButton ? min(width, max(view.fittingSize.width, attributed.size().width + 2 * Metrics.space3)) : width
            view.frame = NSRect(x: max(0, (available - width) / 2), y: y, width: rowWidth, height: rowHeight)
            y += rowHeight
        }
        document.frame = NSRect(x: 0, y: 0, width: available, height: max(scroll.contentSize.height, y + Metrics.space5))
    }
}
