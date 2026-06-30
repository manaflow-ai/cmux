import Foundation

/// UI-agnostic collaboration session state and document mutation API.
public actor CollaborationSession {
    private let peerID: String
    private let displayName: String
    private let color: String
    private let sessionID: String
    private let store: any CollaborationFileStoring
    private let reconciler: DiskReconciler
    private let hash = TextHash()
    private var documents: [String: OpenCollaborationDocument] = [:]
    private var presenceByPeer: [String: PresenceState] = [:]
    private var presenceSequence = 0
    private var connectionState: CollaborationConnectionState = .idle
    private var continuation: AsyncStream<CollaborationEvent>.Continuation?

    /// Creates a collaboration session.
    /// - Parameters:
    ///   - peerID: The local peer identifier.
    ///   - displayName: The local peer's display name.
    ///   - color: The local peer's display color.
    ///   - sessionID: The collaboration session identifier.
    ///   - store: File storage used for open/close reconciliation.
    public init(
        peerID: String,
        displayName: String,
        color: String,
        sessionID: String,
        store: any CollaborationFileStoring = LocalCollaborationFileStore()
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.color = color
        self.sessionID = sessionID
        self.store = store
        self.reconciler = DiskReconciler(store: store)
    }

    /// Events emitted by this session.
    public var events: AsyncStream<CollaborationEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Marks the relay as connected.
    public func markConnected() {
        setConnectionState(.connected)
    }

    /// Returns the current relay connection state.
    /// - Returns: The current relay connection state.
    public func currentConnectionState() -> CollaborationConnectionState {
        connectionState
    }

    /// Marks the relay as unavailable before session start.
    public func markRelayUnavailable() {
        setConnectionState(.relayUnavailable)
    }

    /// Marks the relay as disconnected after session start.
    public func markDisconnected() {
        setConnectionState(.disconnected)
        for peer in presenceByPeer.keys {
            continuation?.yield(.presenceCleared(peerID: peer))
        }
        presenceByPeer.removeAll()
    }

    /// Opens a local file as a collaboration document.
    /// - Parameter file: The file to open.
    /// - Returns: The initial document snapshot.
    public func open(file: SharedFileDescriptor) async throws -> CollaborationDocumentSnapshot {
        let text = try await store.readText(at: file.localURL)
        let baselineHash = hash.hash(text)
        let documentID = file.documentID(sessionID: sessionID)
        let open = OpenCollaborationDocument(
            file: file,
            document: CollaborationTextDocument(text: text, peerID: peerID),
            baselineHash: baselineHash,
            lastWrittenHash: nil
        )
        documents[documentID] = open
        let snapshot = CollaborationDocumentSnapshot(documentID: documentID, text: text, textHash: baselineHash)
        continuation?.yield(.documentChanged(snapshot))
        return snapshot
    }

    /// Applies a local edit and returns the CRDT update frame to broadcast.
    /// - Parameters:
    ///   - file: The edited file.
    ///   - range: The visible character range to replace.
    ///   - replacement: The replacement text.
    /// - Returns: A relay frame containing generated CRDT operations.
    public func applyLocalEdit(
        file: SharedFileDescriptor,
        range: Range<Int>,
        replacement: String
    ) async throws -> CollaborationRelayFrame {
        let documentID = file.documentID(sessionID: sessionID)
        guard var open = documents[documentID] else {
            throw CollaborationSessionError.documentNotOpen(documentID)
        }
        let operations = open.document.replace(range: range, with: replacement)
        documents[documentID] = open
        let snapshot = CollaborationDocumentSnapshot(
            documentID: documentID,
            text: open.document.text,
            textHash: hash.hash(open.document.text)
        )
        continuation?.yield(.documentChanged(snapshot))
        return .documentUpdate(
            documentID: documentID,
            updateID: "\(peerID)-\(UUID().uuidString)",
            operations: operations
        )
    }

    /// Applies a remote relay frame.
    /// - Parameter frame: The frame received from the relay.
    public func applyRemoteFrame(_ frame: CollaborationRelayFrame) async throws {
        switch frame {
        case let .documentUpdate(documentID, _, operations):
            try merge(operations: operations, documentID: documentID)
        case let .documentSnapshot(documentID, _, operations, _):
            try merge(operations: operations, documentID: documentID)
        case .documentSnapshotRequest:
            break
        case let .presence(state):
            let previous = presenceByPeer[state.peerID]
            guard previous == nil || previous!.sequence < state.sequence else { return }
            presenceByPeer[state.peerID] = state
            continuation?.yield(.presenceChanged(state))
        case let .peerLeft(peerID):
            presenceByPeer.removeValue(forKey: peerID)
            continuation?.yield(.presenceCleared(peerID: peerID))
        }
    }

    /// Exports a full-state snapshot frame for a file.
    /// - Parameters:
    ///   - file: The file to snapshot.
    ///   - requestID: The snapshot request identifier, if any.
    /// - Returns: A relay snapshot frame.
    public func snapshotFrame(
        for file: SharedFileDescriptor,
        requestID: String? = nil
    ) async throws -> CollaborationRelayFrame {
        let documentID = file.documentID(sessionID: sessionID)
        guard let open = documents[documentID] else {
            throw CollaborationSessionError.documentNotOpen(documentID)
        }
        return .documentSnapshot(
            documentID: documentID,
            requestID: requestID,
            operations: open.document.snapshotOperations(),
            textHash: hash.hash(open.document.text)
        )
    }

    /// Updates local presence and returns the frame to broadcast.
    /// - Parameters:
    ///   - file: The active file, if any.
    ///   - cursor: The UTF-16 cursor offset.
    ///   - selection: The UTF-16 selection range, if any.
    /// - Returns: A relay frame containing ephemeral presence.
    public func setLocalSelection(
        file: SharedFileDescriptor?,
        cursor: Int,
        selection: Range<Int>?
    ) -> CollaborationRelayFrame {
        presenceSequence += 1
        let state = PresenceState(
            peerID: peerID,
            displayName: displayName,
            color: color,
            activeFile: file?.relativePath,
            cursor: cursor,
            selection: selection,
            sequence: presenceSequence
        )
        return .presence(state)
    }

    /// Closes a file and reconciles its resolved CRDT text to disk.
    /// - Parameter file: The file to close.
    /// - Returns: The disk reconciliation result.
    public func close(file: SharedFileDescriptor) async throws -> DiskReconciliationResult {
        let documentID = file.documentID(sessionID: sessionID)
        guard let open = documents.removeValue(forKey: documentID) else {
            throw CollaborationSessionError.documentNotOpen(documentID)
        }
        let result = try await reconciler.reconcile(
            text: open.document.text,
            fileURL: file.localURL,
            baselineHash: open.baselineHash,
            lastWrittenHash: open.lastWrittenHash
        )
        continuation?.yield(.diskReconciled(result))
        return result
    }

    /// Returns a visible snapshot for the file.
    /// - Parameter file: The file to inspect.
    /// - Returns: The current visible document snapshot.
    public func snapshot(for file: SharedFileDescriptor) throws -> CollaborationDocumentSnapshot {
        let documentID = file.documentID(sessionID: sessionID)
        guard let open = documents[documentID] else {
            throw CollaborationSessionError.documentNotOpen(documentID)
        }
        return CollaborationDocumentSnapshot(
            documentID: documentID,
            text: open.document.text,
            textHash: hash.hash(open.document.text)
        )
    }

    private func merge(operations: [TextOperation], documentID: String) throws {
        guard var open = documents[documentID] else {
            throw CollaborationSessionError.documentNotOpen(documentID)
        }
        open.document.merge(operations)
        documents[documentID] = open
        let snapshot = CollaborationDocumentSnapshot(
            documentID: documentID,
            text: open.document.text,
            textHash: hash.hash(open.document.text)
        )
        continuation?.yield(.documentChanged(snapshot))
    }

    private func setConnectionState(_ state: CollaborationConnectionState) {
        connectionState = state
        continuation?.yield(.connectionChanged(state))
    }
}
