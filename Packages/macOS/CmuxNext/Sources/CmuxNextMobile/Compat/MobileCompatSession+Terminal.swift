import CmuxNextDaemon
import Foundation

/// `mobile.terminal.*` and bare `terminal.*` methods.
extension MobileCompatSession {
    /// Default grid when neither the phone nor the daemon reports one.
    static let fallbackSize = CellSize(cols: 80, rows: 24)

    func dispatchTerminal(_ request: MobileRPCRequest) async throws -> JSONValue? {
        let method = request.method.hasPrefix("mobile.") ? String(request.method.dropFirst(7)) : request.method
        switch method {
        case "terminal.create": return try await createTerminal(request)
        case "terminal.replay": return try await replay(request)
        case "terminal.viewport": return try await viewport(request)
        case "terminal.input": return try await input(request, paste: false)
        case "terminal.paste": return try await input(request, paste: true)
        case "terminal.close": return try await closeTerminal(request)
        case "terminal.rename": return try await renameTerminal(request)
        default: return nil
        }
    }

    private func createTerminal(_ request: MobileRPCRequest) async throws -> JSONValue {
        let key = try workspaceKey(request)
        let terminal = try await backend.createTerminal(in: key, cwd: request.string("cwd"))
        return try await workspaceList(createdTerminal: terminal)
    }

    /// Re-attaches and answers with the daemon's complete VT replay plus the
    /// offset live `terminal.bytes` continue from.
    private func replay(_ request: MobileRPCRequest) async throws -> JSONValue {
        let (surfaceID, location, generation) = try await locate(request)
        let size = requestedSize(request) ?? location.tab.size ?? Self.fallbackSize
        let stream = try await restartStream(surfaceID: surfaceID, tab: location.tab, generation: generation, size: size)
        if requestedSize(request) != nil { await stream.resize(cols: size.cols, rows: size.rows) }
        guard let (snapshot, seq) = await stream.initialReplay() else {
            throw MobileRPCError("terminal_unavailable", "the terminal closed before its replay")
        }
        return .object([
            "workspace_id": .string(MobileCompatIDs.workspaceID(location.workspace)),
            "surface_id": .string(surfaceID),
            "snapshot_data_b64": .string(MobileCompatReplayBytes.snapshot(snapshot).base64EncodedString()),
            "snapshot_format": .string("ghostty.active.vt"),
            "seq": .uint(seq),
            "columns": .int(snapshot.cols),
            "rows": .int(snapshot.rows),
        ])
    }

    /// The phone's visible grid: it owns geometry while it looks at the terminal.
    private func viewport(_ request: MobileRPCRequest) async throws -> JSONValue {
        let (surfaceID, location, generation) = try await locate(request)
        guard let size = requestedSize(request) else {
            throw MobileRPCError.invalidParams("viewport_columns and viewport_rows are required")
        }
        let stream: MobileCompatTerminalStream
        if let existing = streams[surfaceID], await !existing.isEnded {
            stream = existing
        } else {
            stream = try await restartStream(surfaceID: surfaceID, tab: location.tab, generation: generation, size: size)
        }
        await stream.resize(cols: size.cols, rows: size.rows)
        return .object([
            "workspace_id": .string(MobileCompatIDs.workspaceID(location.workspace)),
            "surface_id": .string(surfaceID),
            "columns": .int(size.cols),
            "rows": .int(size.rows),
        ])
    }

    private func input(_ request: MobileRPCRequest, paste: Bool) async throws -> JSONValue {
        // Keystrokes use the last located tab; the tree is refetched only on a miss.
        let (surfaceID, location, _) = try await locate(request, cached: true)
        guard let text = request.params["text"]?.stringValue else {
            throw MobileRPCError.invalidParams("text is required")
        }
        if !text.isEmpty {
            let stream = streams[surfaceID]
                ?? streams.first { $0.key.caseInsensitiveCompare(surfaceID) == .orderedSame }?.value
            await stream?.activate()
            try await backend.send(location.tab.surface, bytes: Data(text.utf8), paste: paste)
        }
        return .object([
            "workspace_id": .string(MobileCompatIDs.workspaceID(location.workspace)),
            "surface_id": .string(surfaceID),
            "queued": .bool(true),
        ])
    }

    private func closeTerminal(_ request: MobileRPCRequest) async throws -> JSONValue {
        let (surfaceID, location, _) = try await locate(request)
        if let stream = streams.removeValue(forKey: surfaceID) {
            surfaceSeq[surfaceID] = await stream.nextSeq
            await stream.stop()
        }
        if let terminal = location.tab.terminalID { try await backend.closeTerminal(terminal) }
        return .object(["surface_id": .string(surfaceID), "closed": .bool(true)])
    }

    private func renameTerminal(_ request: MobileRPCRequest) async throws -> JSONValue {
        let (surfaceID, location, _) = try await locate(request)
        guard let title = (request.string("title") ?? request.string("name"))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw MobileRPCError.invalidParams("title is required")
        }
        try await backend.renameTab(location.tab.surface, to: title)
        return .object(["surface_id": .string(surfaceID), "title": .string(title)])
    }

    // MARK: Helpers

    private func requestedSize(_ request: MobileRPCRequest) -> CellSize? {
        guard let cols = request.int("viewport_columns"), let rows = request.int("viewport_rows"),
              cols > 0, rows > 0 else { return nil }
        return CellSize(cols: cols, rows: rows)
    }

    private func locate(_ request: MobileRPCRequest, cached: Bool = false) async throws
        -> (String, MobileWorkspaceRows.TerminalLocation, DaemonGeneration?) {
        guard let surfaceID = request.string("surface_id") else {
            throw MobileRPCError("terminal_id_required", "surface_id is required")
        }
        if cached, let location = locations[surfaceID.uppercased()] {
            return (surfaceID, location, nil)
        }
        let tree = try await backend.tree()
        guard let location = MobileWorkspaceRows.locate(surfaceID: surfaceID, in: tree) else {
            locations[surfaceID.uppercased()] = nil
            throw MobileRPCError.notFound("no terminal \(surfaceID)")
        }
        locations[surfaceID.uppercased()] = location
        return (surfaceID, location, tree.generation)
    }

    /// Replaces this connection's stream for `surfaceID`, continuing its numbering.
    private func restartStream(surfaceID: String, tab: TabSnapshot, generation: DaemonGeneration?,
                               size: CellSize) async throws -> MobileCompatTerminalStream {
        if let old = streams.removeValue(forKey: surfaceID) {
            surfaceSeq[surfaceID] = await old.nextSeq
            await old.stop()
        }
        let channel = try await backend.attach(tab, generation: generation, size: size)
        let stream = MobileCompatTerminalStream(surfaceID: surfaceID, channel: channel,
                                                startSeq: surfaceSeq[surfaceID] ?? 0)
        streams[surfaceID] = stream
        let emit = emit
        await stream.start { surface, seq, bytes in
            await emit(MobileRPCWire.event(topic: "terminal.bytes", payload: .object([
                "surface_id": .string(surface),
                "seq": .uint(seq),
                "data_b64": .string(bytes.base64EncodedString()),
            ])))
        }
        return stream
    }
}
