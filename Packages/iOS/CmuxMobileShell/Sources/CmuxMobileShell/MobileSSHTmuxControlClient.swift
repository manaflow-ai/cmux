internal import CmuxMobileSSH
import Foundation

/// One `tmux -C` control client for one tmux session, over one SSH exec
/// channel (no PTY, so the stream carries no DCS framing or CRs).
///
/// The client attaches through its OWN grouped session
/// (`new-session -t <session> -s <session>-cmux-ios-<id>`, destroyed when
/// unattached): the group shares windows and panes with the user's session
/// but keeps its own current window, so the phone never switches the window
/// a laptop is looking at. Control mode reports `%output` for every pane in
/// every window of the attached session, so one channel serves every pane
/// surface of the workspace.
///
/// Pane seeding follows the Mac mirror (`RemoteTmuxControlConnection+Commands.swift`
/// `capturePane`): pause this client's output for the pane, read the
/// alternate-screen flag, `capture-pane -e -S -N` (history + screen), read
/// the cursor and mode state, then continue, in one write so the commands run
/// back to back in tmux's command queue. Live `%output` before the capture
/// reply is already in the capture and is dropped; output after it is held
/// until the snapshot is delivered.
@MainActor
final class MobileSSHTmuxControlClient {
    /// Lines of history seeded into the phone's scrollback on attach.
    nonisolated static let historyLines = 2_000
    /// Suffix marking the phone's grouped sessions, hidden from the workspace list.
    nonisolated static let groupedSessionMarker = "-cmux-ios-"

    let sessionName: String
    let groupedSessionName: String
    private let channel: SSHSessionChannel
    private var parser = MobileSSHTmuxControlParser()
    /// Reply handlers for this client's commands, in send order.
    private var pendingReplies: [((lines: [Data], isError: Bool)) -> Void] = []
    private var writeChain: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var panes: [Int: Pane] = [:]
    /// Pane geometry per window, from `%layout-change` and `list-panes`.
    private(set) var leavesByWindow: [Int: [MobileSSHTmuxLayout.Leaf]] = [:]
    private var clientSize: (columns: Int, rows: Int)?
    private(set) var isClosed = false
    /// Windows or panes were added, closed, or renamed.
    var onTopologyChange: (@MainActor () -> Void)?
    /// The control client ended (session killed, connection lost, `%exit`).
    var onClose: (@MainActor () -> Void)?

    private struct Pane {
        var events: @MainActor (MobileSSHAttachEvent) -> Void
        var state: SeedState
        var grid: (columns: Int, rows: Int)?
    }

    private enum SeedState {
        /// Output predates the capture; the capture covers it.
        case awaitingCapture
        /// Output after the capture, held until the snapshot is delivered.
        case awaitingState(buffered: Data)
        case live
    }

    private init(sessionName: String, groupedSessionName: String, channel: SSHSessionChannel) {
        self.sessionName = sessionName
        self.groupedSessionName = groupedSessionName
        self.channel = channel
    }

    /// Starts `tmux -C` in a new grouped session of `session`.
    static func open(connection: SSHConnection, tmuxPath: String, session: String) async throws -> MobileSSHTmuxControlClient {
        let grouped = session + groupedSessionMarker + UUID().uuidString.prefix(8).lowercased()
        let tmux = MobileSSHShell.quote(tmuxPath)
        let command = "\(tmux) -C new-session -t \(MobileSSHShell.quote("=" + session)) -s \(MobileSSHShell.quote(grouped))"
            + " \\; set-option -t \(MobileSSHShell.quote(grouped)) destroy-unattached on"
        let channel = try await connection.openSession(environment: ["LANG": "en_US.UTF-8"], start: .exec(command))
        let client = MobileSSHTmuxControlClient(sessionName: session, groupedSessionName: grouped, channel: channel)
        client.startPump()
        // Learn the geometry of every pane before any seed needs it.
        let lines = try await client.command("list-panes -s -F '#{window_id} #{pane_id} #{pane_width}x#{pane_height}'")
        for line in lines {
            let fields = String(decoding: line, as: UTF8.self).split(separator: " ")
            guard fields.count == 3,
                  let window = MobileSSHTmuxControlParser.id(String(fields[0]), "@"),
                  let pane = MobileSSHTmuxControlParser.id(String(fields[1]), "%") else { continue }
            let size = fields[2].split(separator: "x").compactMap { Int($0) }
            guard size.count == 2 else { continue }
            client.leavesByWindow[window, default: []].append(
                MobileSSHTmuxLayout.Leaf(pane: pane, columns: size[0], rows: size[1], x: 0, y: 0)
            )
        }
        return client
    }

    private func startPump() {
        pump = Task { @MainActor [weak self] in
            guard let events = self?.channel.events else { return }
            for await event in events {
                guard let self else { return }
                switch event {
                case .stdout(let data):
                    for message in self.parser.feed(data) { self.handle(message) }
                case .closed:
                    self.finish()
                case .stderr, .exitStatus, .exitSignal:
                    break
                }
            }
        }
    }

    // MARK: Commands

    /// Sends command lines in one write, registering a reply handler for each.
    private func enqueue(_ commands: [(line: String, reply: ((lines: [Data], isError: Bool)) -> Void)]) {
        guard !isClosed else {
            for command in commands { command.reply(([], true)) }
            return
        }
        var payload = Data()
        for command in commands {
            pendingReplies.append(command.reply)
            payload.append(Data((command.line + "\n").utf8))
        }
        let previous = writeChain
        let channel = channel
        writeChain = Task { @MainActor in
            await previous?.value
            try? await channel.write(payload)
        }
    }

    /// Runs one command and returns its output lines; `%error` throws.
    func command(_ line: String) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            enqueue([(line, { reply in
                if reply.isError {
                    let message = reply.lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
                    continuation.resume(throwing: SSHConnectionError.channelRequestRejected("tmux \(line): \(message)"))
                } else {
                    continuation.resume(returning: reply.lines)
                }
            })])
        }
    }

    /// Sends a command whose reply does not matter.
    func send(_ line: String) {
        enqueue([(line, { _ in })])
    }

    // MARK: Panes

    /// Starts streaming one pane: `.remoteGrid`, then `.snapshot`, then live output.
    func attach(pane: Int, events: @escaping @MainActor (MobileSSHAttachEvent) -> Void) {
        panes[pane] = Pane(events: events, state: .awaitingCapture, grid: nil)
        var alternate = false
        enqueue([
            ("refresh-client -A '%\(pane):pause'", { _ in }), // tmux < 3.2 rejects this; the seed still works
            ("display-message -p -t %\(pane) -F '#{alternate_on}'", { reply in
                alternate = reply.lines.first.map { String(decoding: $0, as: UTF8.self) } == "1"
            }),
            ("capture-pane -p -e -S -\(Self.historyLines) -t %\(pane)", { [weak self] reply in
                self?.captured(pane: pane, rows: reply.isError ? nil : reply.lines, alternate: alternate)
            }),
            ("display-message -p -t %\(pane) -F '\(Self.stateFormat)'", { [weak self] reply in
                self?.seeded(pane: pane, stateLine: reply.isError ? nil : reply.lines.first)
            }),
            ("refresh-client -A '%\(pane):continue'", { _ in }),
        ])
    }

    private var pendingSnapshots: [Int: Data] = [:]

    private func captured(pane: Int, rows: [Data]?, alternate: Bool) {
        guard panes[pane] != nil else { return }
        guard let rows else {
            // The pane vanished between listing and attach.
            end(pane: pane)
            return
        }
        var snapshot = Data()
        if alternate { snapshot.append(Data("\u{1B}[?1049h".utf8)) }
        snapshot.append(Data("\u{1B}[H\u{1B}[2J".utf8))
        snapshot.append(Self.joinRows(rows))
        pendingSnapshots[pane] = snapshot
        panes[pane]?.state = .awaitingState(buffered: Data())
    }

    private func seeded(pane: Int, stateLine: Data?) {
        guard var entry = panes[pane], case .awaitingState(let buffered) = entry.state,
              var snapshot = pendingSnapshots.removeValue(forKey: pane) else { return }
        let fields = stateLine.map { Self.fields(String(decoding: $0, as: UTF8.self)) } ?? [:]
        snapshot.append(Self.stateSequence(fields))
        if let columns = fields["pane_width"].flatMap(Int.init), let rows = fields["pane_height"].flatMap(Int.init) {
            entry.grid = (columns, rows)
        } else {
            entry.grid = leaf(pane: pane).map { ($0.columns, $0.rows) }
        }
        entry.state = .live
        panes[pane] = entry
        if let grid = entry.grid { entry.events(.remoteGrid(columns: grid.columns, rows: grid.rows)) }
        entry.events(.snapshot(snapshot))
        if !buffered.isEmpty { entry.events(.output(buffered)) }
    }

    /// Stops streaming one pane. The pane keeps running in tmux.
    func detach(pane: Int) {
        panes[pane] = nil
        pendingSnapshots[pane] = nil
    }

    var attachedPaneCount: Int { panes.count }

    /// Types bytes into a pane (`send-keys -H`: binary-safe, no quoting).
    func write(_ data: Data, pane: Int) {
        guard !data.isEmpty else { return }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: 256, limitedBy: data.endIndex) ?? data.endIndex
            let hex = data[start..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
            send("send-keys -t %\(pane) -H \(hex)")
            start = end
        }
    }

    /// Sizes this control client (and so, with `window-size latest`, the
    /// session's windows while the phone is the most recent client).
    func setClientSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        if let clientSize, clientSize == (columns, rows) { return }
        clientSize = (columns, rows)
        send("refresh-client -C \(columns)x\(rows)")
    }

    func leaf(pane: Int) -> MobileSSHTmuxLayout.Leaf? {
        for leaves in leavesByWindow.values {
            if let leaf = leaves.first(where: { $0.pane == pane }) { return leaf }
        }
        return nil
    }

    /// Detaches the control client; its grouped session is destroyed.
    func close() async {
        guard !isClosed else { return }
        send("kill-session -t \(Self.quoteForTmux(groupedSessionName))")
        await writeChain?.value
        await channel.close()
        finish()
    }

    // MARK: Stream

    private func handle(_ message: MobileSSHTmuxControlMessage) {
        switch message {
        case .output(let pane, let data):
            guard var entry = panes[pane] else { return }
            switch entry.state {
            case .awaitingCapture:
                break
            case .awaitingState(var buffered):
                buffered.append(data)
                entry.state = .awaitingState(buffered: buffered)
                panes[pane] = entry
            case .live:
                entry.events(.output(data))
            }
        case .reply(_, let flags, let lines, let isError):
            // Flag 1 marks replies to this client's own commands; the
            // startup command line's blocks carry flag 0.
            guard flags & 1 == 1, !pendingReplies.isEmpty else { return }
            pendingReplies.removeFirst()((lines, isError))
        case .layoutChange(let window, let layout, let visible):
            var leaves = MobileSSHTmuxLayout.leaves(layout)
            // A zoomed window shows one pane at full size.
            if let visible {
                for leaf in MobileSSHTmuxLayout.leaves(visible) {
                    if let index = leaves.firstIndex(where: { $0.pane == leaf.pane }) { leaves[index] = leaf }
                }
            }
            let before = Set((leavesByWindow[window] ?? []).map(\.pane))
            leavesByWindow[window] = leaves
            updateGrids()
            if before != Set(leaves.map(\.pane)) {
                endVanishedPanes()
                onTopologyChange?()
            }
        case .windowAdd, .windowRenamed:
            onTopologyChange?()
        case .windowClose(let window):
            leavesByWindow[window] = nil
            endVanishedPanes()
            onTopologyChange?()
        case .exit:
            finish()
        case .sessionChanged, .sessionsChanged, .sessionWindowChanged, .windowPaneChanged, .paneModeChanged, .other:
            break
        }
    }

    private func updateGrids() {
        for (pane, entry) in panes {
            guard case .live = entry.state, let leaf = leaf(pane: pane) else { continue }
            if let grid = entry.grid, grid == (leaf.columns, leaf.rows) { continue }
            panes[pane]?.grid = (leaf.columns, leaf.rows)
            entry.events(.remoteGrid(columns: leaf.columns, rows: leaf.rows))
        }
    }

    private func endVanishedPanes() {
        let live = Set(leavesByWindow.values.flatMap { $0.map(\.pane) })
        for pane in panes.keys where !live.contains(pane) { end(pane: pane) }
    }

    private func end(pane: Int) {
        guard let entry = panes.removeValue(forKey: pane) else { return }
        pendingSnapshots[pane] = nil
        entry.events(.ended)
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        let handlers = pendingReplies
        pendingReplies.removeAll()
        for handler in handlers { handler(([], true)) }
        for pane in Array(panes.keys) { end(pane: pane) }
        pump?.cancel()
        onClose?()
    }

    // MARK: Encoding

    /// Captured rows joined by CRLF. The last row gets no newline so the
    /// cursor ends on the bottom row; the state sequence then places it.
    nonisolated static func joinRows(_ rows: [Data]) -> Data {
        var bytes = Data()
        for (index, row) in rows.enumerated() {
            if index > 0 { bytes.append(Data("\r\n".utf8)) }
            bytes.append(row)
        }
        return bytes
    }

    /// Pane state read after the capture (the Mac's `paneStateQueryCommand`
    /// plus the pane size).
    nonisolated static let stateFormat = "cursor_x=#{cursor_x},cursor_y=#{cursor_y},"
        + "scroll_region_upper=#{scroll_region_upper},scroll_region_lower=#{scroll_region_lower},"
        + "cursor_flag=#{cursor_flag},insert_flag=#{insert_flag},"
        + "keypad_cursor_flag=#{keypad_cursor_flag},keypad_flag=#{keypad_flag},"
        + "wrap_flag=#{wrap_flag},origin_flag=#{origin_flag},pane_width=#{pane_width},pane_height=#{pane_height},"
        + "mouse_all_flag=#{mouse_all_flag},mouse_button_flag=#{mouse_button_flag},"
        + "mouse_standard_flag=#{mouse_standard_flag},"
        + "mouse_sgr_flag=#{mouse_sgr_flag},mouse_utf8_flag=#{mouse_utf8_flag}"

    nonisolated static func fields(_ line: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in line.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        return fields
    }

    /// Restores terminal state the capture does not carry (ported from the
    /// Mac's `RemoteTmuxControlMessageDecoding.paneStateSeedSequence`):
    /// scroll region, DEC modes, mouse tracking, origin mode, and the cursor
    /// LAST, because DECSTBM and DECOM both home the cursor.
    nonisolated static func stateSequence(_ fields: [String: String]) -> Data {
        let on: (String) -> Bool = { fields[$0] == "1" }
        // Values come from the server; clamp so arithmetic cannot trap.
        let num: (String) -> Int? = { fields[$0].flatMap(Int.init).flatMap { (0...65_535).contains($0) ? $0 : nil } }
        var seq = "\u{1B}[m"
        let upper = num("scroll_region_upper")
        var restricted = false
        if let upper, let lower = num("scroll_region_lower"), lower >= upper {
            let fullWindow = upper == 0 && (num("pane_height").map { lower == $0 - 1 } ?? false)
            if !fullWindow {
                seq += "\u{1B}[\(upper + 1);\(lower + 1)r"
                restricted = true
            }
        }
        seq += on("wrap_flag") ? "\u{1B}[?7h" : "\u{1B}[?7l"
        seq += on("cursor_flag") ? "\u{1B}[?25h" : "\u{1B}[?25l"
        seq += on("insert_flag") ? "\u{1B}[4h" : "\u{1B}[4l"
        seq += on("keypad_cursor_flag") ? "\u{1B}[?1h" : "\u{1B}[?1l"
        seq += on("keypad_flag") ? "\u{1B}=" : "\u{1B}>"
        seq += "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1005l\u{1B}[?1006l"
        if on("mouse_all_flag") { seq += "\u{1B}[?1003h" }
        else if on("mouse_button_flag") { seq += "\u{1B}[?1002h" }
        else if on("mouse_standard_flag") { seq += "\u{1B}[?1000h" }
        if on("mouse_sgr_flag") { seq += "\u{1B}[?1006h" }
        else if on("mouse_utf8_flag") { seq += "\u{1B}[?1005h" }
        let origin = on("origin_flag")
        seq += origin ? "\u{1B}[?6h" : "\u{1B}[?6l"
        if let x = num("cursor_x"), let y = num("cursor_y") {
            let row = origin && restricted ? max(0, y - (upper ?? 0)) : y
            seq += "\u{1B}[\(row + 1);\(x + 1)H"
        }
        return Data(seq.utf8)
    }

    /// Quotes a word for tmux's command parser (double quotes; `\`, `"`,
    /// and `$` escaped so nothing expands).
    nonisolated static func quoteForTmux(_ word: String) -> String {
        var out = "\""
        for character in word {
            if "\\\"$".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out + "\""
    }
}
