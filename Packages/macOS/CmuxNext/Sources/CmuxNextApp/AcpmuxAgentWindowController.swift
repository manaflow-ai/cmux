import AppKit
import CmuxNextDaemon

/// A native Mac ACPmux surface. It owns no agent state: all session state is
/// read from ACPmux, so closing this window cannot interrupt an agent turn.
@MainActor
final class AcpmuxAgentWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let service: AcpmuxAgentService
    private var sessions: [AcpmuxAgentService.Session] = []
    private var selectedSessionID: String?
    private let sessionTable = NSTableView()
    private let transcript = NSTextView()
    private let composer = NSTextView()
    private let status = NSTextField(labelWithString: "Ready")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let newButton = NSButton(title: "New session", target: nil, action: nil)

    init(service: AcpmuxAgentService) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Agent Chat"
        window.minSize = NSSize(width: 680, height: 460)
        super.init(window: window)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)

        let sidebar = NSView()
        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.spacing = 8
        sidebarStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)
        NSLayoutConstraint.activate([
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])
        let heading = NSTextField(labelWithString: "Sessions")
        heading.font = .boldSystemFont(ofSize: 13)
        sidebarStack.addArrangedSubview(heading)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.title = "Agent sessions"
        sessionTable.addTableColumn(column)
        sessionTable.headerView = nil
        sessionTable.delegate = self
        sessionTable.dataSource = self
        sessionTable.rowHeight = 46
        scroll.documentView = sessionTable
        sidebarStack.addArrangedSubview(scroll)
        newButton.target = self
        newButton.action = #selector(newSession)
        sidebarStack.addArrangedSubview(newButton)
        split.addArrangedSubview(sidebar)

        let main = NSView()
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.spacing = 10
        mainStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: main.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: main.bottomAnchor),
        ])
        transcript.isEditable = false
        transcript.isRichText = false
        transcript.font = .systemFont(ofSize: 14)
        transcript.textContainerInset = NSSize(width: 12, height: 12)
        let transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.documentView = transcript
        mainStack.addArrangedSubview(transcriptScroll)
        status.textColor = .secondaryLabelColor
        mainStack.addArrangedSubview(status)
        composer.isRichText = false
        composer.font = .systemFont(ofSize: 14)
        composer.isVerticallyResizable = true
        composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        composer.textContainerInset = NSSize(width: 8, height: 8)
        mainStack.addArrangedSubview(composer)
        sendButton.target = self
        sendButton.action = #selector(sendPrompt)
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        let controls = NSStackView(views: [sendButton])
        controls.orientation = .horizontal
        controls.alignment = .trailing
        mainStack.addArrangedSubview(controls)
        split.addArrangedSubview(main)
        split.setPosition(250, ofDividerAt: 0)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    @objc private func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                sessions = try await service.listSessions()
                sessionTable.reloadData()
                if selectedSessionID == nil { selectedSessionID = sessions.first?.id }
                if let id = selectedSessionID { try await load(id: id) }
                status.stringValue = sessions.isEmpty ? "No sessions. Create one to begin." : "Connected to ACPmux"
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func newSession() {
        status.stringValue = "Starting session…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await service.createSession(model: "claude")
                selectedSessionID = session.id
                sessions = try await service.listSessions()
                sessionTable.reloadData()
                try await load(id: session.id)
                status.stringValue = "Session (session.name) is ready"
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    @objc private func sendPrompt() {
        guard let id = selectedSessionID else {
            status.stringValue = "Create or select a session first"
            return
        }
        let prompt = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        composer.string = ""
        append(role: "You", text: prompt)
        status.stringValue = "Agent is working…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reply = try await service.send(sessionID: id, prompt: prompt)
                append(role: "Agent", text: reply)
                status.stringValue = "Ready"
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    private func load(id: String) async throws {
        selectedSessionID = id
        let turns = try await service.history(sessionID: id)
        transcript.string = turns.map { "\($0.role.capitalized)\n\($0.text)" }.joined(separator: "\n\n")
        transcript.scrollToEndOfDocument(nil)
    }

    private func append(role: String, text: String) {
        let prefix = transcript.string.isEmpty ? "" : "\n\n"
        transcript.string += "\(prefix)\(role)\n\(text)"
        transcript.scrollToEndOfDocument(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = sessions[row]
        let cell = NSTableCellView()
        let label = NSTextField(wrappingLabelWithString: "\(session.name)\n\(session.status)")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        cell.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sessionTable.selectedRow
        guard row >= 0, row < sessions.count else { return }
        let id = sessions[row].id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await load(id: id); status.stringValue = "Connected to ACPmux" }
            catch { status.stringValue = error.localizedDescription }
        }
    }
}

