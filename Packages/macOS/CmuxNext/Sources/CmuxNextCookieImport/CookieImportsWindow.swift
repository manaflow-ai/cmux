public import AppKit
import CmuxNextDesign

/// The Cookie Imports window (`browser.cookieImports`): every cookie import request from the
/// audit ledger, newest first, with who asked, why, from where into which cmux profile, the
/// answer, the sites that came in (with counts) and Remove for imports whose cookies are still
/// in. It reads the ledger each time it shows; it never shows a cookie value (the ledger has none).
@MainActor
public final class CookieImportsWindow: NSObject {
    private let ledger: CookieImportLedger
    private let remove: @MainActor (String) async throws -> CookieImportRecord
    private var window: NSWindow?
    private let list = NSStackView()
    private var load: Task<Void, Never>?

    /// - Parameters:
    ///   - ledger: The audit ledger it lists.
    ///   - remove: Removes one import's cookies (``CookieImportService/remove(_:)``).
    public init(ledger: CookieImportLedger, remove: @escaping @MainActor (String) async throws -> CookieImportRecord) {
        self.ledger = ledger
        self.remove = remove
        super.init()
    }

    /// Shows the window (made on first use) and lists the ledger as it is now.
    public func show() {
        let window = self.window ?? make()
        self.window = window
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = CookieImportStrings.windowTitle
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("app.cookieImports")
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 14
        list.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        window.contentView = scroll
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        window.center()
        return window
    }

    private func reload() {
        load?.cancel()
        // task-owner: one ledger read per show or removal; cancelled by the next one
        load = Task { @MainActor [weak self] in
            guard let self else { return }
            let records = await ledger.records()
            guard !Task.isCancelled else { return }
            fill(Array(records.reversed()))
        }
    }

    private func fill(_ records: [CookieImportRecord]) {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        add(Self.label(CookieImportStrings.windowLead, size: TypeScale.detail, secondary: true))
        guard !records.isEmpty else { return add(Self.label(CookieImportStrings.windowEmpty, size: TypeScale.detail)) }
        for record in records { add(row(record)) }
    }

    private func add(_ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -36).isActive = true
    }

    private func row(_ record: CookieImportRecord) -> NSView {
        let date = record.date.formatted(date: .abbreviated, time: .shortened)
        let outcome = CookieImportStrings.outcome(record.outcome, removed: record.removedAt != nil)
        let header = Self.label("\(outcome) · \(date)", size: TypeScale.detail, weight: TypeScale.emphasis)
        let who = record.requester.kind == "person" ? CookieImportStrings.person : Self.requesterName(record.requester)
        var lines = ["\(CookieImportStrings.requestedBy): \(who)", "\(record.source) → \(record.targetProfileName)"]
        if !record.reason.isEmpty { lines.append("“\(record.reason)”") }
        let sites = record.sites.map { CookieImportStrings.siteCount($0.host, $0.count) }
        if !sites.isEmpty {
            lines.append("\(CookieImportStrings.sitesLabel): \(sites.joined(separator: ", "))")
        } else if !record.requestedSites.isEmpty {
            lines.append("\(CookieImportStrings.sitesLabel): \(record.requestedSites.joined(separator: ", "))")
        }
        if let failure = record.failure { lines.append(failure) }
        let detail = Self.label(lines.joined(separator: "\n"), size: TypeScale.detail, secondary: true)
        let row = NSStackView(views: [header, detail])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        if record.canRemove {
            let button = ThemedBezelButton(title: CookieImportStrings.remove, target: self, action: #selector(removePressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(record.id)
            button.setAccessibilityIdentifier("app.cookieImports.remove." + record.id)
            row.addArrangedSubview(button)
        }
        for view in [header, detail] { view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
        return row
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self] in  // task-owner: one removal the person pressed, then one reload
            guard let self else { return }
            _ = try? await remove(id)
            reload()
        }
    }

    private static func requesterName(_ requester: CookieImportRecord.Requester) -> String {
        let kind: CookieImportRequester.Kind = switch requester.kind {
        case "agentChat": .agentChat
        case "homeChief": .homeChief
        case "terminal": .terminal
        default: .unknown
        }
        return CookieImportRequester(kind: kind, name: requester.name).reference
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = TypeScale.regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.isSelectable = true
        label.focusRingType = .none
        return label
    }
}

/// A top-down document view for the window's scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
