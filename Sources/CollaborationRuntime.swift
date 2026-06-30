import AppKit
import CmuxCollaboration
import Foundation
import Observation
import SwiftUI

@MainActor
protocol CollaborationEditablePanel: AnyObject {
    var collaborationFileURL: URL { get }
    var collaborationFilePath: String { get }
    var collaborationText: String { get }

    func applyCollaborationText(_ text: String)
}

struct CollaborationDocumentHeaderState: Equatable {
    var isShared = false
    var statusText = ""
    var peerSummary = ""
}

private struct CollaborationCreateSessionResponse: Decodable {
    let sessionID: String
    let sessionCode: String
    let token: String
}

private struct CollaborationPeerWire: Codable {
    let peerID: String
    let displayName: String
    let color: String
}

private struct CollaborationJoinedWire: Decodable {
    let sessionID: String
    let peers: [CollaborationPeerWire]
}

private struct CollaborationFrameType: Decodable {
    let type: String
}

private struct CollaborationHeartbeatWire: Codable {
    let type = "peer.heartbeat"
}

private struct CollaborationDocumentUpdateWire: Codable {
    let type: String
    let documentID: String
    let updateID: String
    let operations: [TextOperation]
}

private struct CollaborationDocumentSnapshotWire: Codable {
    let type: String
    let documentID: String
    let requestID: String?
    let operations: [TextOperation]
    let textHash: String
}

private struct CollaborationDocumentSnapshotRequestWire: Codable {
    let type: String
    let documentID: String
    let requestID: String
}

private struct CollaborationTerminalOpenWire: Codable {
    let type: String
    let terminalID: String
    let descriptor: SharedTerminalDescriptor
}

private struct CollaborationTerminalOutputWire: Codable {
    let type: String
    let terminalID: String
    let sequence: UInt64
    let dataBase64: String
    let fromPeerID: String?
    let caretPeerID: String?

    init(
        type: String,
        terminalID: String,
        sequence: UInt64,
        dataBase64: String,
        fromPeerID: String? = nil,
        caretPeerID: String? = nil
    ) {
        self.type = type
        self.terminalID = terminalID
        self.sequence = sequence
        self.dataBase64 = dataBase64
        self.fromPeerID = fromPeerID
        self.caretPeerID = caretPeerID
    }
}

private struct CollaborationTerminalInputWire: Codable {
    let type: String
    let terminalID: String
    let inputID: String
    let dataBase64: String
    let fromPeerID: String?

    init(type: String, terminalID: String, inputID: String, dataBase64: String, fromPeerID: String? = nil) {
        self.type = type
        self.terminalID = terminalID
        self.inputID = inputID
        self.dataBase64 = dataBase64
        self.fromPeerID = fromPeerID
    }
}

private struct CollaborationTerminalPointerWire: Codable {
    let type: String
    let terminalID: String
    let fromPeerID: String
    let x: Double
    let y: Double
    let visible: Bool
}

private struct CollaborationTerminalSelectionRectWire: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct CollaborationTerminalSelectionWire: Codable {
    let type: String
    let terminalID: String
    let fromPeerID: String
    let rects: [CollaborationTerminalSelectionRectWire]
    let visible: Bool
}

private struct CollaborationTerminalCloseWire: Codable {
    let type: String
    let terminalID: String
}

private struct CollaborationPresenceWire: Codable {
    let type: String
    let peerID: String
    let displayName: String
    let color: String
    let activeFile: String?
    let cursor: Int
    let selectionLowerBound: Int?
    let selectionUpperBound: Int?
    let sequence: Int

    init(state: PresenceState) {
        self.type = "presence.update"
        self.peerID = state.peerID
        self.displayName = state.displayName
        self.color = state.color
        self.activeFile = state.activeFile
        self.cursor = state.cursor
        self.selectionLowerBound = state.selection?.lowerBound
        self.selectionUpperBound = state.selection?.upperBound
        self.sequence = state.sequence
    }

    var presenceState: PresenceState {
        let range: Range<Int>?
        if let selectionLowerBound, let selectionUpperBound {
            range = selectionLowerBound..<selectionUpperBound
        } else {
            range = nil
        }
        return PresenceState(
            peerID: peerID,
            displayName: displayName,
            color: color,
            activeFile: activeFile,
            cursor: cursor,
            selection: range,
            sequence: sequence
        )
    }
}

private struct CollaborationPeerLeftWire: Decodable {
    let peerID: String
}

private final class WeakCollaborationPanel {
    weak var panel: (any CollaborationEditablePanel)?

    init(_ panel: any CollaborationEditablePanel) {
        self.panel = panel
    }
}

private final class WeakCollaborationTerminalPanel {
    weak var panel: TerminalPanel?

    init(_ panel: TerminalPanel) {
        self.panel = panel
    }
}

private struct TerminalOutputCaretSuppression {
    let expiresAt: Date
}

struct CollaborationTerminalHeaderState: Equatable {
    var isShared = false
    var statusText = ""
    var peerSummary = ""
}

@MainActor
@Observable
final class CollaborationRuntime {
    static let shared = CollaborationRuntime()
    private static let defaultRelayURLString = "https://collaboration.cmux.dev"

    private(set) var relayURLString = CollaborationRuntime.defaultRelayURLString
    private(set) var sessionCode: String?
    private(set) var inviteToken: String?
    private(set) var connectionLabel = CollaborationStrings.disconnected
    private(set) var lastErrorMessage: String?

    private let peerIdentity: CollaborationPeerIdentity
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var session: CollaborationSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var sessionEventsTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var panelsByDocumentID: [String: WeakCollaborationPanel] = [:]
    private var descriptorsByDocumentID: [String: SharedFileDescriptor] = [:]
    private var statesByDocumentID: [String: CollaborationDocumentHeaderState] = [:]
    private var hostedTerminalsByID: [String: WeakCollaborationTerminalPanel] = [:]
    private var hostedTerminalIDsBySurfaceID: [UUID: String] = [:]
    private var hostedTerminalOutputSequencesByID: [String: UInt64] = [:]
    private var hostedTerminalOutputCaretSuppressionsByID: [String: TerminalOutputCaretSuppression] = [:]
    private var mirroredTerminalsByID: [String: WeakCollaborationTerminalPanel] = [:]
    private var mirroredTerminalIDsBySurfaceID: [UUID: String] = [:]
    private var terminalStatesByID: [String: CollaborationTerminalHeaderState] = [:]
    private var peersByID: [String: CollaborationPeerWire] = [:]
    private var terminalPointerLastSentAtBySurfaceID: [UUID: TimeInterval] = [:]
    private var terminalSelectionLastSentAtBySurfaceID: [UUID: TimeInterval] = [:]
    private var snapshotFallbackTasks: [String: Task<Void, Never>] = [:]

    private init() {
        let displayName = NSFullUserName().isEmpty ? Host.current().localizedName ?? "cmux" : NSFullUserName()
        peerIdentity = CollaborationPeerIdentity.ephemeral(displayName: displayName)
    }

    private static func normalizedRelayURL(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultRelayURLString : trimmed
    }

    func state(for panel: any CollaborationEditablePanel) -> CollaborationDocumentHeaderState {
        let descriptor = descriptor(for: panel)
        let documentID = descriptor.documentID(sessionID: sessionCode ?? "")
        return statesByDocumentID[documentID] ?? CollaborationDocumentHeaderState(
            isShared: false,
            statusText: connectionLabel,
            peerSummary: peerSummary
        )
    }

    func configureOrShare(panel: any CollaborationEditablePanel) {
        if session == nil {
            presentStartDialog(thenShare: panel)
            return
        }
        share(panel: panel)
    }

    func state(for terminal: TerminalPanel) -> CollaborationTerminalHeaderState {
        let terminalID = terminalID(for: terminal)
        return terminalStatesByID[terminalID] ?? CollaborationTerminalHeaderState(
            isShared: false,
            statusText: connectionLabel,
            peerSummary: peerSummary
        )
    }

    func configureOrShare(terminal: TerminalPanel) {
        if session == nil {
            presentStartDialog()
            return
        }
        if state(for: terminal).isShared {
            leave(terminal: terminal)
            return
        }
        share(terminal: terminal)
    }

    func leave(terminal: TerminalPanel) {
        let terminalID = terminalID(for: terminal)
        hostedTerminalsByID.removeValue(forKey: terminalID)
        removeTerminalSurfaceMappings(for: terminalID)
        hostedTerminalOutputSequencesByID.removeValue(forKey: terminalID)
        hostedTerminalOutputCaretSuppressionsByID.removeValue(forKey: terminalID)
        mirroredTerminalsByID.removeValue(forKey: terminalID)
        terminalStatesByID.removeValue(forKey: terminalID)
        Task {
            try? await send(.terminalClose(terminalID: terminalID))
        }
    }

    func noteTerminalOutput(surfaceID: UUID, data: Data) {
        guard let terminalID = hostedTerminalIDsBySurfaceID[surfaceID] else { return }
        let sequence = hostedTerminalOutputSequencesByID[terminalID] ?? 0
        hostedTerminalOutputSequencesByID[terminalID] = sequence &+ UInt64(data.count)
        Task {
            try? await send(.terminalOutput(terminalID: terminalID, sequence: sequence, data: data))
        }
    }

    func noteTerminalInput(terminalID: String, data: Data) {
        Task {
            try? await send(.terminalInput(
                terminalID: terminalID,
                inputID: "\(peerIdentity.peerID)-\(UUID().uuidString)",
                data: data
            ))
        }
    }

    func noteTerminalPointer(surfaceID: UUID, point: CGPoint?, bounds: CGRect, visible: Bool) {
        let terminalID = hostedTerminalIDsBySurfaceID[surfaceID] ?? mirroredTerminalIDsBySurfaceID[surfaceID]
        guard let terminalID else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if visible {
            let lastSentAt = terminalPointerLastSentAtBySurfaceID[surfaceID] ?? 0
            guard now - lastSentAt >= (1.0 / 60.0) else { return }
            terminalPointerLastSentAtBySurfaceID[surfaceID] = now
        } else {
            terminalPointerLastSentAtBySurfaceID.removeValue(forKey: surfaceID)
        }

        let normalizedX: Double
        let normalizedY: Double
        if visible, let point, bounds.width > 0, bounds.height > 0 {
            normalizedX = Double(min(max(point.x / bounds.width, 0), 1))
            normalizedY = Double(min(max(point.y / bounds.height, 0), 1))
        } else {
            normalizedX = 0
            normalizedY = 0
        }

        Task {
            try? await send(CollaborationTerminalPointerWire(
                type: "terminal.pointer",
                terminalID: terminalID,
                fromPeerID: peerIdentity.peerID,
                x: normalizedX,
                y: normalizedY,
                visible: visible
            ))
        }
    }

    func noteTerminalSelection(surfaceID: UUID, rects: [CGRect], bounds: CGRect, visible: Bool) {
        let terminalID = hostedTerminalIDsBySurfaceID[surfaceID] ?? mirroredTerminalIDsBySurfaceID[surfaceID]
        guard let terminalID else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if visible {
            let lastSentAt = terminalSelectionLastSentAtBySurfaceID[surfaceID] ?? 0
            guard now - lastSentAt >= (1.0 / 12.0) else { return }
            terminalSelectionLastSentAtBySurfaceID[surfaceID] = now
        } else {
            terminalSelectionLastSentAtBySurfaceID.removeValue(forKey: surfaceID)
        }

        let normalizedRects: [CollaborationTerminalSelectionRectWire]
        if visible, bounds.width > 0, bounds.height > 0 {
            normalizedRects = rects.compactMap { rect in
                let clipped = rect.intersection(bounds)
                guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
                return CollaborationTerminalSelectionRectWire(
                    x: Double(clipped.minX / bounds.width),
                    y: Double(clipped.minY / bounds.height),
                    width: Double(clipped.width / bounds.width),
                    height: Double(clipped.height / bounds.height)
                )
            }
        } else {
            normalizedRects = []
        }

        Task {
            try? await send(CollaborationTerminalSelectionWire(
                type: "terminal.selection",
                terminalID: terminalID,
                fromPeerID: peerIdentity.peerID,
                rects: normalizedRects,
                visible: visible && !normalizedRects.isEmpty
            ))
        }
    }

    private func peerVisibleToThisClient(_ peerID: String?) -> CollaborationPeerWire? {
        guard let peerID, peerID != peerIdentity.peerID else { return nil }
        return peersByID[peerID] ?? CollaborationPeerWire(
            peerID: peerID,
            displayName: peerID,
            color: peerIdentity.color
        )
    }

    private func terminalOutputPeerID(for terminalID: String) -> String? {
        if let suppression = hostedTerminalOutputCaretSuppressionsByID[terminalID] {
            if suppression.expiresAt > Date() {
                return nil
            }
            hostedTerminalOutputCaretSuppressionsByID.removeValue(forKey: terminalID)
        }
        return peerIdentity.peerID
    }

    private func removeTerminalSurfaceMappings(for terminalID: String) {
        let hostedSurfaceIDs = hostedTerminalIDsBySurfaceID
            .filter { $0.value == terminalID }
            .map(\.key)
        let mirroredSurfaceIDs = mirroredTerminalIDsBySurfaceID
            .filter { $0.value == terminalID }
            .map(\.key)

        hostedTerminalIDsBySurfaceID = hostedTerminalIDsBySurfaceID.filter { $0.value != terminalID }
        mirroredTerminalIDsBySurfaceID = mirroredTerminalIDsBySurfaceID.filter { $0.value != terminalID }
        for surfaceID in hostedSurfaceIDs + mirroredSurfaceIDs {
            terminalPointerLastSentAtBySurfaceID.removeValue(forKey: surfaceID)
            terminalSelectionLastSentAtBySurfaceID.removeValue(forKey: surfaceID)
        }
    }

    func leave(panel: any CollaborationEditablePanel) {
        guard let session else { return }
        let descriptor = descriptor(for: panel)
        let documentID = descriptor.documentID(sessionID: sessionCode ?? "")
        panelsByDocumentID.removeValue(forKey: documentID)
        descriptorsByDocumentID.removeValue(forKey: documentID)
        statesByDocumentID.removeValue(forKey: documentID)
        snapshotFallbackTasks[documentID]?.cancel()
        snapshotFallbackTasks.removeValue(forKey: documentID)
        Task {
            _ = try? await session.close(file: descriptor)
        }
    }

    func noteLocalTextChange(panel: any CollaborationEditablePanel, previousText: String, nextText: String) {
        guard let session else { return }
        let descriptor = descriptor(for: panel)
        let documentID = descriptor.documentID(sessionID: sessionCode ?? "")
        guard panelsByDocumentID[documentID]?.panel != nil else { return }
        let edit = CollaborationTextDiff.diff(previous: previousText, next: nextText)
        Task {
            do {
                let frame = try await session.applyLocalEdit(
                    file: descriptor,
                    range: edit.range,
                    replacement: edit.replacement
                )
                try await send(frame)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func noteLocalSelection(panel: any CollaborationEditablePanel, textView: NSTextView) {
        guard let session else { return }
        let selectedRange = textView.selectedRange()
        let selection: Range<Int>?
        if selectedRange.length > 0 {
            selection = selectedRange.location..<(selectedRange.location + selectedRange.length)
        } else {
            selection = nil
        }
        let descriptor = descriptor(for: panel)
        Task {
            let frame = await session.setLocalSelection(
                file: descriptor,
                cursor: selectedRange.location,
                selection: selection
            )
            try? await send(frame)
        }
    }

    func statusSummary() -> String {
        if let sessionCode {
            return "\(CollaborationStrings.connected): \(sessionCode)"
        }
        return connectionLabel
    }

    func statusPayload() -> [String: Any] {
        [
            "connected": session != nil,
            "relay_url": relayURLString,
            "session_code": sessionCode ?? NSNull(),
            "invite_token": inviteToken ?? NSNull(),
            "status": connectionLabel,
            "shared_documents": statesByDocumentID.values.filter(\.isShared).count,
            "shared_terminals": terminalStatesByID.values.filter(\.isShared).count,
            "peers": peersByID.values.map { peer in
                [
                    "peer_id": peer.peerID,
                    "display_name": peer.displayName,
                    "color": peer.color,
                ]
            },
        ]
    }

    func createSessionForAutomation(relayURL: String?) async -> [String: Any] {
        if let relayURL {
            relayURLString = Self.normalizedRelayURL(from: relayURL)
        }
        do {
            let response = try await createSession()
            await connect(sessionID: response.sessionID, code: response.sessionCode, token: response.token)
            var payload = statusPayload()
            payload["session_code"] = response.sessionCode
            payload["invite_token"] = response.token
            return payload
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionLabel = CollaborationStrings.connectionFailed
            return [
                "connected": false,
                "status": connectionLabel,
                "error": error.localizedDescription,
            ]
        }
    }

    func createSessionForAutomationRequest(relayURL: String?) -> [String: Any] {
        Task { @MainActor in
            _ = await createSessionForAutomation(relayURL: relayURL)
        }
        return [
            "requested": true,
            "status": CollaborationStrings.connecting,
        ]
    }

    func joinSessionForAutomation(relayURL: String?, code: String, token: String) async -> [String: Any] {
        if let relayURL {
            relayURLString = Self.normalizedRelayURL(from: relayURL)
        }
        await joinSession(code: code, token: token)
        return statusPayload()
    }

    func joinSessionForAutomationRequest(relayURL: String?, code: String, token: String) -> [String: Any] {
        Task { @MainActor in
            _ = await joinSessionForAutomation(relayURL: relayURL, code: code, token: token)
        }
        return [
            "requested": true,
            "session_code": code,
            "status": CollaborationStrings.connecting,
        ]
    }

    func shareSelectedTerminalForAutomation() -> [String: Any] {
        guard let workspace = TerminalController.shared.tabManager?.selectedWorkspace
            ?? TerminalController.shared.tabManager?.tabs.first else {
            return [
                "shared": false,
                "error": CollaborationStrings.noWorkspaceForTerminalShare,
            ]
        }
        guard let terminal = workspace.focusedTerminalPanel
            ?? workspace.panels.values.compactMap({ $0 as? TerminalPanel }).first else {
            return [
                "shared": false,
                "error": CollaborationStrings.terminalShareFailed,
            ]
        }
        configureOrShare(terminal: terminal)
        return statusPayload()
    }

    func leaveSessionForAutomation() -> [String: Any] {
        disconnectWebSocket()
        session = nil
        sessionCode = nil
        inviteToken = nil
        panelsByDocumentID.removeAll()
        descriptorsByDocumentID.removeAll()
        statesByDocumentID.removeAll()
        hostedTerminalsByID.removeAll()
        hostedTerminalIDsBySurfaceID.removeAll()
        hostedTerminalOutputSequencesByID.removeAll()
        hostedTerminalOutputCaretSuppressionsByID.removeAll()
        mirroredTerminalsByID.removeAll()
        mirroredTerminalIDsBySurfaceID.removeAll()
        terminalStatesByID.removeAll()
        peersByID.removeAll()
        terminalPointerLastSentAtBySurfaceID.removeAll()
        terminalSelectionLastSentAtBySurfaceID.removeAll()
        connectionLabel = CollaborationStrings.disconnected
        return statusPayload()
    }

    private func presentStartDialog() {
        let alert = NSAlert()
        alert.messageText = CollaborationStrings.startTitle
        alert.informativeText = CollaborationStrings.startMessage
        alert.addButton(withTitle: CollaborationStrings.createSession)
        alert.addButton(withTitle: CollaborationStrings.joinSession)
        alert.addButton(withTitle: CollaborationStrings.cancel)

        let relayField = NSTextField(string: relayURLString)
        relayField.placeholderString = CollaborationStrings.relayURLPlaceholder
        relayField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = relayField

        let response = alert.runModal()
        relayURLString = Self.normalizedRelayURL(from: relayField.stringValue)
        switch response {
        case .alertFirstButtonReturn:
            Task { _ = await createSessionForAutomation(relayURL: relayURLString) }
        case .alertSecondButtonReturn:
            presentJoinDialog()
        default:
            break
        }
    }

    private func presentJoinDialog() {
        let alert = NSAlert()
        alert.messageText = CollaborationStrings.joinSession
        alert.informativeText = CollaborationStrings.joinMessage
        alert.addButton(withTitle: CollaborationStrings.joinSession)
        alert.addButton(withTitle: CollaborationStrings.cancel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        let codeField = NSTextField(string: "")
        codeField.placeholderString = CollaborationStrings.sessionCodePlaceholder
        let tokenField = NSTextField(string: "")
        tokenField.placeholderString = CollaborationStrings.inviteTokenPlaceholder
        stack.addArrangedSubview(codeField)
        stack.addArrangedSubview(tokenField)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await joinSession(code: code, token: token) }
    }

    private func presentStartDialog(thenShare panel: any CollaborationEditablePanel) {
        let alert = NSAlert()
        alert.messageText = CollaborationStrings.startTitle
        alert.informativeText = CollaborationStrings.startMessage
        alert.addButton(withTitle: CollaborationStrings.createSession)
        alert.addButton(withTitle: CollaborationStrings.joinSession)
        alert.addButton(withTitle: CollaborationStrings.cancel)

        let relayField = NSTextField(string: relayURLString)
        relayField.placeholderString = CollaborationStrings.relayURLPlaceholder
        relayField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = relayField

        let response = alert.runModal()
        relayURLString = Self.normalizedRelayURL(from: relayField.stringValue)
        switch response {
        case .alertFirstButtonReturn:
            Task { await createSessionAndShare(panel: panel) }
        case .alertSecondButtonReturn:
            presentJoinDialog(thenShare: panel)
        default:
            break
        }
    }

    private func presentJoinDialog(thenShare panel: any CollaborationEditablePanel) {
        let alert = NSAlert()
        alert.messageText = CollaborationStrings.joinSession
        alert.informativeText = CollaborationStrings.joinMessage
        alert.addButton(withTitle: CollaborationStrings.joinSession)
        alert.addButton(withTitle: CollaborationStrings.cancel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        let codeField = NSTextField(string: "")
        codeField.placeholderString = CollaborationStrings.sessionCodePlaceholder
        let tokenField = NSTextField(string: "")
        tokenField.placeholderString = CollaborationStrings.inviteTokenPlaceholder
        stack.addArrangedSubview(codeField)
        stack.addArrangedSubview(tokenField)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await joinSession(code: code, token: token)
            share(panel: panel)
        }
    }

    private func createSessionAndShare(panel: any CollaborationEditablePanel) async {
        do {
            let response = try await createSession()
            await connect(sessionID: response.sessionID, code: response.sessionCode, token: response.token)
            share(panel: panel)
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionLabel = CollaborationStrings.connectionFailed
        }
    }

    private func joinSession(code: String, token: String) async {
        await connect(sessionID: code, code: code, token: token)
    }

    private func createSession() async throws -> CollaborationCreateSessionResponse {
        guard let url = URL(string: relayURLString)?
            .appending(path: "v1")
            .appending(path: "collaboration")
            .appending(path: "sessions") else {
            throw CollaborationRuntimeError.invalidRelayURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CollaborationRuntimeError.relayRejected
        }
        return try decoder.decode(CollaborationCreateSessionResponse.self, from: data)
    }

    private func connect(sessionID: String, code: String, token: String) async {
        disconnectWebSocket()
        sessionCode = code
        inviteToken = token
        connectionLabel = CollaborationStrings.connecting
        let nextSession = CollaborationSession(
            peerID: peerIdentity.peerID,
            displayName: peerIdentity.displayName,
            color: peerIdentity.color,
            sessionID: sessionID
        )
        session = nextSession
        observe(session: nextSession)

        guard let url = connectURL(code: code, token: token) else {
            connectionLabel = CollaborationStrings.connectionFailed
            await nextSession.markRelayUnavailable()
            return
        }
        let task = URLSession.shared.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        receiveNextMessage()
        startHeartbeatLoop()
        await nextSession.markConnected()
        connectionLabel = CollaborationStrings.connected
        reopenSharedDocumentsForCurrentSession()
        reopenSharedTerminalsForCurrentSession()
    }

    private func connectURL(code: String, token: String) -> URL? {
        guard var components = URLComponents(string: relayURLString) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/collaboration/sessions/\(code)/connect"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "peerID", value: peerIdentity.peerID),
            URLQueryItem(name: "displayName", value: peerIdentity.displayName),
            URLQueryItem(name: "color", value: peerIdentity.color),
        ]
        return components.url
    }

    private func observe(session: CollaborationSession) {
        sessionEventsTask?.cancel()
        sessionEventsTask = Task { [weak self] in
            let events = await session.events
            for await event in events {
                await self?.handle(event: event)
            }
        }
    }

    private func share(panel: any CollaborationEditablePanel) {
        guard let session, let sessionCode else { return }
        let descriptor = descriptor(for: panel)
        let documentID = descriptor.documentID(sessionID: sessionCode)
        panelsByDocumentID[documentID] = WeakCollaborationPanel(panel)
        descriptorsByDocumentID[documentID] = descriptor
        statesByDocumentID[documentID] = CollaborationDocumentHeaderState(
            isShared: true,
            statusText: CollaborationStrings.shared,
            peerSummary: peerSummary
        )
        Task {
            do {
                _ = try await session.open(file: descriptor)
                if peersByID.isEmpty {
                    try await send(try await session.snapshotFrame(for: descriptor))
                } else {
                    let requestID = UUID().uuidString
                    try await sendSnapshotRequest(documentID: documentID, requestID: requestID)
                    scheduleSnapshotFallback(descriptor: descriptor, documentID: documentID)
                }
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func share(terminal: TerminalPanel) {
        guard session != nil, let sessionCode else { return }
        let descriptor = terminalDescriptor(for: terminal)
        let terminalID = descriptor.terminalID(sessionID: sessionCode)
        hostedTerminalsByID[terminalID] = WeakCollaborationTerminalPanel(terminal)
        hostedTerminalIDsBySurfaceID[terminal.id] = terminalID
        terminalStatesByID[terminalID] = CollaborationTerminalHeaderState(
            isShared: true,
            statusText: CollaborationStrings.shared,
            peerSummary: peerSummary
        )
        Task {
            do {
                try await send(.terminalOpen(terminalID: terminalID, descriptor: descriptor))
                if let replay = MobileTerminalByteTee.shared.replayState(surfaceID: terminal.id),
                   !replay.data.isEmpty {
                    try await send(.terminalOutput(terminalID: terminalID, sequence: replay.seq, data: replay.data))
                }
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func reopenSharedDocumentsForCurrentSession() {
        guard let session, let sessionCode else { return }
        let openPanels = panelsByDocumentID.values.compactMap(\.panel)
        guard !openPanels.isEmpty else { return }

        snapshotFallbackTasks.values.forEach { $0.cancel() }
        snapshotFallbackTasks.removeAll()

        panelsByDocumentID.removeAll()
        descriptorsByDocumentID.removeAll()
        statesByDocumentID.removeAll()

        for panel in openPanels {
            let descriptor = descriptor(for: panel)
            let documentID = descriptor.documentID(sessionID: sessionCode)
            panelsByDocumentID[documentID] = WeakCollaborationPanel(panel)
            descriptorsByDocumentID[documentID] = descriptor
            statesByDocumentID[documentID] = CollaborationDocumentHeaderState(
                isShared: true,
                statusText: CollaborationStrings.shared,
                peerSummary: peerSummary
            )
            Task {
                do {
                    _ = try await session.open(file: descriptor)
                    try await send(try await session.snapshotFrame(for: descriptor))
                } catch {
                    lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func reopenSharedTerminalsForCurrentSession() {
        guard let sessionCode else { return }
        let openTerminals = hostedTerminalsByID.values.compactMap(\.panel)
        guard !openTerminals.isEmpty else { return }

        hostedTerminalsByID.removeAll()
        hostedTerminalIDsBySurfaceID.removeAll()
        hostedTerminalOutputSequencesByID.removeAll()
        hostedTerminalOutputCaretSuppressionsByID.removeAll()
        terminalStatesByID.removeAll()

        for terminal in openTerminals {
            let descriptor = terminalDescriptor(for: terminal)
            let terminalID = descriptor.terminalID(sessionID: sessionCode)
            hostedTerminalsByID[terminalID] = WeakCollaborationTerminalPanel(terminal)
            hostedTerminalIDsBySurfaceID[terminal.id] = terminalID
            terminalStatesByID[terminalID] = CollaborationTerminalHeaderState(
                isShared: true,
                statusText: CollaborationStrings.shared,
                peerSummary: peerSummary
            )
            Task {
                try? await send(.terminalOpen(terminalID: terminalID, descriptor: descriptor))
            }
        }
    }

    private func scheduleSnapshotFallback(descriptor: SharedFileDescriptor, documentID: String) {
        snapshotFallbackTasks[documentID]?.cancel()
        snapshotFallbackTasks[documentID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.sendLocalSnapshotIfOpen(descriptor: descriptor)
        }
    }

    private func sendLocalSnapshotIfOpen(descriptor: SharedFileDescriptor) async {
        guard let session else { return }
        do {
            try await send(try await session.snapshotFrame(for: descriptor))
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func handleRemoteTerminalOpen(terminalID: String, descriptor: SharedTerminalDescriptor) {
        if mirroredTerminalsByID[terminalID]?.panel != nil { return }
        let title = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? CollaborationStrings.sharedTerminalTitle : title
        guard let workspace = TerminalController.shared.tabManager?.selectedWorkspace
            ?? TerminalController.shared.tabManager?.tabs.first else {
            lastErrorMessage = CollaborationStrings.noWorkspaceForTerminalShare
            return
        }
        guard let panel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: terminalID.hashValue,
            title: displayTitle,
            focus: false,
            onInput: { [terminalID] data in
                Task { @MainActor in
                    CollaborationRuntime.shared.noteTerminalInput(terminalID: terminalID, data: data)
                }
            }
        ) else {
            lastErrorMessage = CollaborationStrings.terminalShareFailed
            return
        }
        mirroredTerminalsByID[terminalID] = WeakCollaborationTerminalPanel(panel)
        mirroredTerminalIDsBySurfaceID[panel.id] = terminalID
        terminalStatesByID[terminalID] = CollaborationTerminalHeaderState(
            isShared: true,
            statusText: CollaborationStrings.shared,
            peerSummary: peerSummary
        )
    }

    private func handleRemoteTerminalOutput(terminalID: String, data: Data, caretPeerID: String?) {
        guard let panel = mirroredTerminalsByID[terminalID]?.panel else { return }
        panel.surface.processRemoteOutput(data)
        if let peer = peerVisibleToThisClient(caretPeerID) {
            panel.surface.hostedView.showTerminalCollaboratorCaret(
                peerID: peer.peerID,
                displayName: peer.displayName,
                colorHex: peer.color
            )
        }
    }

    private func handleRemoteTerminalInput(terminalID: String, data: Data, fromPeerID: String?) {
        guard let panel = hostedTerminalsByID[terminalID]?.panel else { return }
        if let peer = peerVisibleToThisClient(fromPeerID) {
            hostedTerminalOutputCaretSuppressionsByID[terminalID] = TerminalOutputCaretSuppression(
                expiresAt: Date().addingTimeInterval(1.5)
            )
            panel.surface.hostedView.showTerminalCollaboratorCaret(
                peerID: peer.peerID,
                displayName: peer.displayName,
                colorHex: peer.color
            )
        }
        let text = String(decoding: data, as: UTF8.self)
        switch panel.sendInputResult(text) {
        case .sent:
            panel.surface.forceRefresh(reason: "collaboration.terminalInput")
        case .queued, .inputQueueFull, .surfaceUnavailable, .processExited:
            break
        }
    }

    private func handleRemoteTerminalPointer(_ pointer: CollaborationTerminalPointerWire) {
        guard let peer = peerVisibleToThisClient(pointer.fromPeerID) else { return }
        let panels = [
            hostedTerminalsByID[pointer.terminalID]?.panel,
            mirroredTerminalsByID[pointer.terminalID]?.panel
        ].compactMap { $0 }

        for panel in panels {
            panel.surface.hostedView.showTerminalCollaboratorPointer(
                peerID: peer.peerID,
                displayName: peer.displayName,
                colorHex: peer.color,
                normalizedX: pointer.x,
                normalizedY: pointer.y,
                visible: pointer.visible
            )
        }
    }

    private func handleRemoteTerminalSelection(_ selection: CollaborationTerminalSelectionWire) {
        guard let peer = peerVisibleToThisClient(selection.fromPeerID) else { return }
        let panels = [
            hostedTerminalsByID[selection.terminalID]?.panel,
            mirroredTerminalsByID[selection.terminalID]?.panel
        ].compactMap { $0 }

        let rects = selection.rects.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        for panel in panels {
            panel.surface.hostedView.showTerminalCollaboratorSelection(
                peerID: peer.peerID,
                colorHex: peer.color,
                normalizedRects: rects,
                visible: selection.visible
            )
        }
    }

    private func handleRemoteTerminalClose(terminalID: String) {
        mirroredTerminalsByID.removeValue(forKey: terminalID)
        hostedTerminalsByID.removeValue(forKey: terminalID)
        removeTerminalSurfaceMappings(for: terminalID)
        hostedTerminalOutputSequencesByID.removeValue(forKey: terminalID)
        hostedTerminalOutputCaretSuppressionsByID.removeValue(forKey: terminalID)
        terminalStatesByID.removeValue(forKey: terminalID)
    }

    private func handle(event: CollaborationEvent) async {
        switch event {
        case .documentChanged(let snapshot):
            guard let panel = panelsByDocumentID[snapshot.documentID]?.panel else { return }
            panel.applyCollaborationText(snapshot.text)
            updateState(documentID: snapshot.documentID, isShared: true)
        case .presenceChanged:
            refreshPeerSummaries()
        case .presenceCleared(let peerID):
            peersByID.removeValue(forKey: peerID)
            refreshPeerSummaries()
        case .connectionChanged(let state):
            connectionLabel = label(for: state)
        case .diskReconciled:
            break
        }
    }

    private func receiveNextMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                await self?.handleReceive(result)
            }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) async {
        switch result {
        case .failure(let error):
            lastErrorMessage = error.localizedDescription
            connectionLabel = CollaborationStrings.disconnected
            await session?.markDisconnected()
        case .success(let message):
            do {
                let data: Data
                switch message {
                case .string(let string):
                    data = Data(string.utf8)
                case .data(let frameData):
                    data = frameData
                @unknown default:
                    receiveNextMessage()
                    return
                }
                try await handleFrameData(data)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            receiveNextMessage()
        }
    }

    private func handleFrameData(_ data: Data) async throws {
        let frameType = try decoder.decode(CollaborationFrameType.self, from: data)
        switch frameType.type {
        case "session.joined":
            let joined = try decoder.decode(CollaborationJoinedWire.self, from: data)
            peersByID = Dictionary(uniqueKeysWithValues: joined.peers.filter { $0.peerID != peerIdentity.peerID }.map { ($0.peerID, $0) })
            refreshPeerSummaries()
        case "peer.joined":
            let peer = try decoder.decode(CollaborationPeerJoinedWire.self, from: data).peer
            if peer.peerID != peerIdentity.peerID {
                peersByID[peer.peerID] = peer
                refreshPeerSummaries()
            }
        case "peer.left":
            let left = try decoder.decode(CollaborationPeerLeftWire.self, from: data)
            peersByID.removeValue(forKey: left.peerID)
            refreshPeerSummaries()
            try await session?.applyRemoteFrame(.peerLeft(peerID: left.peerID))
        case "document.update":
            let update = try decoder.decode(CollaborationDocumentUpdateWire.self, from: data)
            try await session?.applyRemoteFrame(.documentUpdate(
                documentID: update.documentID,
                updateID: update.updateID,
                operations: update.operations
            ))
        case "document.snapshot":
            let snapshot = try decoder.decode(CollaborationDocumentSnapshotWire.self, from: data)
            snapshotFallbackTasks[snapshot.documentID]?.cancel()
            snapshotFallbackTasks.removeValue(forKey: snapshot.documentID)
            try await session?.applyRemoteFrame(.documentSnapshot(
                documentID: snapshot.documentID,
                requestID: snapshot.requestID,
                operations: snapshot.operations,
                textHash: snapshot.textHash
            ))
        case "document.snapshot.request":
            let request = try decoder.decode(CollaborationDocumentSnapshotRequestWire.self, from: data)
            if let descriptor = descriptorsByDocumentID[request.documentID],
               let session {
                try await send(try await session.snapshotFrame(for: descriptor, requestID: request.requestID))
            }
        case "presence.update":
            let presence = try decoder.decode(CollaborationPresenceWire.self, from: data)
            try await session?.applyRemoteFrame(.presence(presence.presenceState))
        case "terminal.open":
            let open = try decoder.decode(CollaborationTerminalOpenWire.self, from: data)
            handleRemoteTerminalOpen(terminalID: open.terminalID, descriptor: open.descriptor)
        case "terminal.output":
            let output = try decoder.decode(CollaborationTerminalOutputWire.self, from: data)
            if let bytes = Data(base64Encoded: output.dataBase64) {
                handleRemoteTerminalOutput(terminalID: output.terminalID, data: bytes, caretPeerID: output.caretPeerID)
            }
        case "terminal.input":
            let input = try decoder.decode(CollaborationTerminalInputWire.self, from: data)
            if let bytes = Data(base64Encoded: input.dataBase64) {
                handleRemoteTerminalInput(terminalID: input.terminalID, data: bytes, fromPeerID: input.fromPeerID)
            }
        case "terminal.pointer":
            let pointer = try decoder.decode(CollaborationTerminalPointerWire.self, from: data)
            handleRemoteTerminalPointer(pointer)
        case "terminal.selection":
            let selection = try decoder.decode(CollaborationTerminalSelectionWire.self, from: data)
            handleRemoteTerminalSelection(selection)
        case "terminal.close":
            let close = try decoder.decode(CollaborationTerminalCloseWire.self, from: data)
            handleRemoteTerminalClose(terminalID: close.terminalID)
        default:
            break
        }
    }

    private func send(_ frame: CollaborationRelayFrame) async throws {
        switch frame {
        case .documentUpdate(let documentID, let updateID, let operations):
            try await send(CollaborationDocumentUpdateWire(
                type: "document.update",
                documentID: documentID,
                updateID: updateID,
                operations: operations
            ))
        case .documentSnapshot(let documentID, let requestID, let operations, let textHash):
            try await send(CollaborationDocumentSnapshotWire(
                type: "document.snapshot",
                documentID: documentID,
                requestID: requestID,
                operations: operations,
                textHash: textHash
            ))
        case .documentSnapshotRequest(let documentID, let requestID):
            try await sendSnapshotRequest(documentID: documentID, requestID: requestID)
        case .presence(let state):
            try await send(CollaborationPresenceWire(state: state))
        case .terminalOpen(let terminalID, let descriptor):
            try await send(CollaborationTerminalOpenWire(
                type: "terminal.open",
                terminalID: terminalID,
                descriptor: descriptor
            ))
        case .terminalOutput(let terminalID, let sequence, let data):
            let caretPeerID = terminalOutputPeerID(for: terminalID)
            try await send(CollaborationTerminalOutputWire(
                type: "terminal.output",
                terminalID: terminalID,
                sequence: sequence,
                dataBase64: data.base64EncodedString(),
                caretPeerID: caretPeerID
            ))
        case .terminalInput(let terminalID, let inputID, let data):
            try await send(CollaborationTerminalInputWire(
                type: "terminal.input",
                terminalID: terminalID,
                inputID: inputID,
                dataBase64: data.base64EncodedString(),
                fromPeerID: peerIdentity.peerID
            ))
        case .terminalClose(let terminalID):
            try await send(CollaborationTerminalCloseWire(type: "terminal.close", terminalID: terminalID))
        case .peerLeft:
            break
        }
    }

    private func sendSnapshotRequest(documentID: String, requestID: String) async throws {
        try await send(CollaborationDocumentSnapshotRequestWire(
            type: "document.snapshot.request",
            documentID: documentID,
            requestID: requestID
        ))
    }

    private func send<T: Encodable>(_ frame: T) async throws {
        guard let webSocketTask else { throw CollaborationRuntimeError.notConnected }
        let data = try encoder.encode(frame)
        let text = String(decoding: data, as: UTF8.self)
        try await webSocketTask.send(.string(text))
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.send(CollaborationHeartbeatWire())
                    // Collaboration relay expires peers after 30 seconds; 10 seconds tolerates missed beats.
                    try await Task.sleep(for: .seconds(10))
                } catch is CancellationError {
                    return
                } catch {
                    await self?.recordHeartbeatFailure(error)
                    return
                }
            }
        }
    }

    private func recordHeartbeatFailure(_ error: any Error) {
        lastErrorMessage = error.localizedDescription
    }

    private func updateState(documentID: String, isShared: Bool) {
        statesByDocumentID[documentID] = CollaborationDocumentHeaderState(
            isShared: isShared,
            statusText: isShared ? CollaborationStrings.shared : connectionLabel,
            peerSummary: peerSummary
        )
    }

    private func refreshPeerSummaries() {
        for documentID in statesByDocumentID.keys {
            updateState(documentID: documentID, isShared: statesByDocumentID[documentID]?.isShared ?? false)
        }
        for terminalID in terminalStatesByID.keys {
            terminalStatesByID[terminalID] = CollaborationTerminalHeaderState(
                isShared: terminalStatesByID[terminalID]?.isShared ?? false,
                statusText: terminalStatesByID[terminalID]?.isShared == true ? CollaborationStrings.shared : connectionLabel,
                peerSummary: peerSummary
            )
        }
    }

    private var peerSummary: String {
        if peersByID.isEmpty { return CollaborationStrings.noPeers }
        if peersByID.count == 1 { return CollaborationStrings.onePeer }
        return String(format: CollaborationStrings.peerCountFormat, peersByID.count)
    }

    private func label(for state: CollaborationConnectionState) -> String {
        switch state {
        case .idle:
            return CollaborationStrings.disconnected
        case .connected:
            return CollaborationStrings.connected
        case .relayUnavailable:
            return CollaborationStrings.connectionFailed
        case .disconnected:
            return CollaborationStrings.disconnected
        case .resynchronizing:
            return CollaborationStrings.resynchronizing
        }
    }

    private func descriptor(for panel: any CollaborationEditablePanel) -> SharedFileDescriptor {
        let root = CollaborationRepositoryResolver.repositoryRoot(for: panel.collaborationFileURL)
        let relativePath: String
        if let root {
            relativePath = panel.collaborationFileURL.path.replacingOccurrences(
                of: root.path.hasSuffix("/") ? root.path : root.path + "/",
                with: ""
            )
        } else {
            relativePath = panel.collaborationFileURL.lastPathComponent
        }
        return SharedFileDescriptor(
            repositoryID: root?.lastPathComponent ?? panel.collaborationFileURL.deletingLastPathComponent().lastPathComponent,
            relativePath: relativePath,
            localURL: panel.collaborationFileURL
        )
    }

    private func terminalDescriptor(for panel: TerminalPanel) -> SharedTerminalDescriptor {
        SharedTerminalDescriptor(
            workspaceID: panel.workspaceId,
            surfaceID: panel.id,
            title: panel.displayTitle
        )
    }

    private func terminalID(for panel: TerminalPanel) -> String {
        terminalDescriptor(for: panel).terminalID(sessionID: sessionCode ?? "")
    }

    private func disconnectWebSocket() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        sessionEventsTask?.cancel()
        sessionEventsTask = nil
    }
}

private struct CollaborationPeerJoinedWire: Decodable {
    let peer: CollaborationPeerWire
}

private enum CollaborationRuntimeError: LocalizedError {
    case invalidRelayURL
    case relayRejected
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            return CollaborationStrings.invalidRelayURL
        case .relayRejected:
            return CollaborationStrings.relayRejected
        case .notConnected:
            return CollaborationStrings.disconnected
        }
    }
}

private enum CollaborationRepositoryResolver {
    static func repositoryRoot(for fileURL: URL) -> URL? {
        var current = fileURL.deletingLastPathComponent()
        while current.path != "/" {
            let gitURL = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitURL.path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }
}

private enum CollaborationTextDiff {
    static func diff(previous: String, next: String) -> (range: Range<Int>, replacement: String) {
        let previousCharacters = Array(previous)
        let nextCharacters = Array(next)
        var prefix = 0
        while prefix < previousCharacters.count,
              prefix < nextCharacters.count,
              previousCharacters[prefix] == nextCharacters[prefix] {
            prefix += 1
        }
        var previousSuffix = previousCharacters.count
        var nextSuffix = nextCharacters.count
        while previousSuffix > prefix,
              nextSuffix > prefix,
              previousCharacters[previousSuffix - 1] == nextCharacters[nextSuffix - 1] {
            previousSuffix -= 1
            nextSuffix -= 1
        }
        return (prefix..<previousSuffix, String(nextCharacters[prefix..<nextSuffix]))
    }
}

enum CollaborationStrings {
    static var collaborate: String {
        String(localized: "collaboration.toolbar.collaborate", defaultValue: "Collaborate")
    }

    static var shareTerminal: String {
        String(localized: "collaboration.terminal.share", defaultValue: "Share Terminal")
    }

    static var stopSharingTerminal: String {
        String(localized: "collaboration.terminal.stopSharing", defaultValue: "Stop Sharing Terminal")
    }

    static var sharedTerminalTitle: String {
        String(localized: "collaboration.terminal.sharedTitle", defaultValue: "Shared Terminal")
    }

    static var noWorkspaceForTerminalShare: String {
        String(localized: "collaboration.terminal.error.noWorkspace", defaultValue: "No workspace is available for the shared terminal.")
    }

    static var terminalShareFailed: String {
        String(localized: "collaboration.terminal.error.shareFailed", defaultValue: "Could not create the shared terminal mirror.")
    }

    static var shared: String {
        String(localized: "collaboration.status.shared", defaultValue: "Shared")
    }

    static var disconnected: String {
        String(localized: "collaboration.status.disconnected", defaultValue: "Not connected")
    }

    static var connecting: String {
        String(localized: "collaboration.status.connecting", defaultValue: "Connecting...")
    }

    static var connected: String {
        String(localized: "collaboration.status.connected", defaultValue: "Connected")
    }

    static var connectionFailed: String {
        String(localized: "collaboration.status.connectionFailed", defaultValue: "Connection failed")
    }

    static var resynchronizing: String {
        String(localized: "collaboration.status.resynchronizing", defaultValue: "Resynchronizing")
    }

    static var noPeers: String {
        String(localized: "collaboration.peers.none", defaultValue: "No peers")
    }

    static var onePeer: String {
        String(localized: "collaboration.peers.one", defaultValue: "1 peer")
    }

    static var peerCountFormat: String {
        String(localized: "collaboration.peers.count", defaultValue: "%d peers")
    }

    static var startTitle: String {
        String(localized: "collaboration.start.title", defaultValue: "Start Collaboration")
    }

    static var startMessage: String {
        String(localized: "collaboration.start.message", defaultValue: "Enter a relay URL, then create a new invite or join an existing one.")
    }

    static var relayURLPlaceholder: String {
        String(localized: "collaboration.relay.urlPlaceholder", defaultValue: "Relay URL")
    }

    static var createSession: String {
        String(localized: "collaboration.action.createSession", defaultValue: "Create Session")
    }

    static var joinSession: String {
        String(localized: "collaboration.action.joinSession", defaultValue: "Join Session")
    }

    static var cancel: String {
        String(localized: "collaboration.action.cancel", defaultValue: "Cancel")
    }

    static var joinMessage: String {
        String(localized: "collaboration.join.message", defaultValue: "Enter the session code and invite token from the collaborator.")
    }

    static var sessionCodePlaceholder: String {
        String(localized: "collaboration.join.sessionCodePlaceholder", defaultValue: "Session code")
    }

    static var inviteTokenPlaceholder: String {
        String(localized: "collaboration.join.inviteTokenPlaceholder", defaultValue: "Invite token")
    }

    static var invalidRelayURL: String {
        String(localized: "collaboration.error.invalidRelayURL", defaultValue: "Invalid relay URL.")
    }

    static var relayRejected: String {
        String(localized: "collaboration.error.relayRejected", defaultValue: "The relay rejected the request.")
    }
}

struct CollaborationHeaderControls<PanelModel>: View where PanelModel: CollaborationEditablePanel {
    @State private var runtime = CollaborationRuntime.shared
    let panel: PanelModel

    var body: some View {
        let state = runtime.state(for: panel)
        HStack(spacing: 6) {
            if state.isShared {
                Text(state.peerSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            PanelHeaderIconButton(
                systemName: state.isShared ? "person.2.fill" : "person.2",
                label: state.isShared ? "\(state.statusText) - \(state.peerSummary)" : CollaborationStrings.collaborate,
                isDisabled: false,
                action: {
                    if state.isShared {
                        runtime.leave(panel: panel)
                    } else {
                        runtime.configureOrShare(panel: panel)
                    }
                }
            )
        }
    }
}
