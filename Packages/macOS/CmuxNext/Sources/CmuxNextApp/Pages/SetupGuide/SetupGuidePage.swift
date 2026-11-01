import AppKit
import CmuxNextActions
import CmuxNextDesign

extension InternalPageID {
    static let setupGuide = InternalPageID(rawValue: "setup-guide")
}

struct SetupGuideSection: Identifiable, Decodable {
    let id: String
    let title: String
    let steps: [String]

    /// The bundled guide (setup-guide.json, written from setup::TASKS by scripts/cmux-next/generate-setup-guide.py),
    /// localized through SetupGuide.xcstrings with the English text as the fallback; empty when the file is missing.
    static let bundled: [SetupGuideSection] = {
        guard let url = Bundle.module.url(forResource: "setup-guide", withExtension: "json"),
              let data = try? Data(contentsOf: url), // concurrency-allow: a small bundled resource, read once
              let entries = try? JSONDecoder().decode([SetupGuideSection].self, from: data) else { return [] }
        func text(_ key: String, _ english: String) -> String {
            Bundle.module.localizedString(forKey: "setupGuide.\(key)", value: english, table: "SetupGuide")
        }
        return entries.map { entry in
            SetupGuideSection(id: entry.id, title: text("\(entry.id).title", entry.title),
                              steps: entry.steps.enumerated().map { text("\(entry.id).\($0.offset)", $0.element) })
        }
    }()
}

/// Offline instructions from setup::TASKS. Reading the guide never checks credentials or starts a login.
@MainActor
final class SetupGuidePage: InternalPageProvider {
    var page: InternalPageID { .setupGuide }
    var title: String { Self.pageTitle }
    var symbol: String { "book" }
    static var pageTitle: String { String(localized: "setupGuide.title", defaultValue: "Setup Guide", table: "SetupGuide", bundle: .module) }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        SetupGuideView()
    }

    static func bind(into registry: ActionRegistry, services: AppServices) {
        services.pages.register(SetupGuidePage())
        registry.bindEffect("help.setupGuide", effect: { [weak services] invocation in
            guard let services, services.pages.show(.setupGuide, in: services.windows.active, focus: invocation.allowsViewChange) != nil else {
                return .refused(RefusalStrings.noWindowOpen)
            }
            return .done
        })
    }
}

/// Static, selectable instructions with native scrolling; no credential reads or automatic actions.
final class SetupGuideView: NSView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView()
    private let document = Document()
    private var lines: [(label: ThemedLabel, gap: CGFloat)] = []
    private let readingWidth: CGFloat

    init(sectionSpacing: CGFloat = Metrics.space5, readingWidth: CGFloat = 680) {
        self.readingWidth = readingWidth
        super.init(frame: .zero)
        setAccessibilityIdentifier("setup-guide")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        SystemScrollers.followThin(scroll)
        scroll.documentView = document
        addSubview(scroll)
        add(SetupGuidePage.pageTitle, font: Typography.title, gap: 0, id: "setup-guide-title")
        for section in SetupGuideSection.bundled {
            add(section.title, font: Typography.bodyEmphasized, gap: sectionSpacing, id: "setup-guide-\(section.id)")
            for (index, step) in section.steps.enumerated() {
                add("\(index + 1). \(step)", font: Typography.body, gap: Metrics.space3,
                    id: "setup-guide-\(section.id)-\(index)")
            }
        }
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
        for (label, gap) in lines {
            y += gap
            let height = ceil(label.attributedStringValue.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
            label.frame = NSRect(x: max(0, (available - width) / 2), y: y, width: width, height: height)
            y += height
        }
        document.frame = NSRect(x: 0, y: 0, width: available, height: max(scroll.contentSize.height, y + Metrics.space5))
    }
}
