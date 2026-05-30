import Foundation

@MainActor
public final class CMUXSidebarExtensionConnection {
    public typealias SnapshotHandler = @MainActor (CMUXSidebarSnapshot) -> Void
    public typealias ErrorHandler = @MainActor (String?) -> Void
    public typealias ActionReplyHandler = @MainActor (CMUXExtensionActionResult) -> Void

    public let manifest: CMUXExtensionManifest

    private let onSnapshot: SnapshotHandler
    private let onError: ErrorHandler
    private var connection: NSXPCConnection?
    private var host: CMUXSidebarHostXPC?
    private var connectionGeneration: UInt64 = 0

    public init(
        manifest: CMUXExtensionManifest,
        onSnapshot: @escaping SnapshotHandler,
        onError: @escaping ErrorHandler = { _ in }
    ) {
        self.manifest = manifest
        self.onSnapshot = onSnapshot
        self.onError = onError
    }

    @discardableResult
    public func accept(_ connection: NSXPCConnection) -> Bool {
        self.connection?.invalidate()
        connectionGeneration += 1
        let generation = connectionGeneration
        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.exportedObject = CMUXSidebarExtensionXPCReceiver(
            manifest: manifest,
            receiveSnapshot: { [weak self] payload, receiverGeneration in
                let snapshotPayload = Data(referencing: payload)
                Task { @MainActor in
                    self?.receive(snapshot: snapshotPayload, ifCurrentGeneration: receiverGeneration)
                }
            },
            generation: generation
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        connection.invalidationHandler = { [weak self, generation] in
            Task { @MainActor in
                self?.clearConnection(ifCurrentGeneration: generation)
            }
        }
        connection.interruptionHandler = { [weak self, generation] in
            Task { @MainActor in
                self?.markInterrupted(ifCurrentGeneration: generation)
            }
        }
        self.connection = connection
        host = connection.remoteObjectProxyWithErrorHandler { [weak self, generation] error in
            Task { @MainActor in
                self?.report(error.localizedDescription, ifCurrentGeneration: generation)
            }
        } as? CMUXSidebarHostXPC
        connection.resume()
        refreshSnapshot()
        return true
    }

    public func refreshSnapshot() {
        guard let host else {
            report("Waiting for cmux", ifCurrentGeneration: connectionGeneration)
            return
        }
        let generation = connectionGeneration
        host.requestSidebarSnapshot { [weak self] payload, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.report(String(error), ifCurrentGeneration: generation)
                    return
                }
                guard let payload else {
                    self.report("cmux did not send a workspace snapshot", ifCurrentGeneration: generation)
                    return
                }
                self.receive(snapshot: Data(referencing: payload), ifCurrentGeneration: generation)
            }
        }
    }

    public func perform(
        _ action: CMUXSidebarAction,
        reply: @escaping ActionReplyHandler = { _ in }
    ) {
        guard let host else {
            report("Waiting for cmux", ifCurrentGeneration: connectionGeneration)
            return
        }
        let generation = connectionGeneration
        do {
            let payload = try CMUXSidebarXPCCodec.encodeAction(action)
            host.performSidebarAction(payload) { [weak self] resultPayload, error in
                guard let self else { return }
                Task { @MainActor in
                    if let error {
                        self.report(String(error), ifCurrentGeneration: generation)
                        return
                    }
                    guard let resultPayload else {
                        self.report("cmux did not send an action result", ifCurrentGeneration: generation)
                        return
                    }
                    do {
                        let result = try CMUXSidebarXPCCodec.decodeActionResult(resultPayload)
                        reply(result)
                        if result.accepted {
                            self.report(nil, ifCurrentGeneration: generation)
                        } else {
                            self.report(result.message, ifCurrentGeneration: generation)
                        }
                    } catch {
                        self.report(error.localizedDescription, ifCurrentGeneration: generation)
                    }
                }
            }
        } catch {
            report(error.localizedDescription, ifCurrentGeneration: generation)
        }
    }

    public func invalidate() {
        connectionGeneration += 1
        connection?.invalidate()
        clearConnection(ifCurrentGeneration: connectionGeneration)
    }

    private func receive(snapshot payload: Data, ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        do {
            let snapshot = try CMUXSidebarXPCCodec.decodeSnapshot(payload as NSData)
            onSnapshot(snapshot)
            onError(nil)
        } catch {
            report(error.localizedDescription, ifCurrentGeneration: generation)
        }
    }

    private func report(_ message: String?, ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        onError(message)
    }

    private func markInterrupted(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        host = nil
        report("Waiting for cmux", ifCurrentGeneration: generation)
    }

    private func clearConnection(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        connection = nil
        host = nil
        report("Waiting for cmux", ifCurrentGeneration: generation)
    }
}

private final class CMUXSidebarExtensionXPCReceiver: NSObject, CMUXSidebarExtensionXPC {
    private let manifest: CMUXExtensionManifest
    private let receiveSnapshot: @Sendable (NSData, UInt64) -> Void
    private let generation: UInt64

    init(
        manifest: CMUXExtensionManifest,
        receiveSnapshot: @escaping @Sendable (NSData, UInt64) -> Void,
        generation: UInt64
    ) {
        self.manifest = manifest
        self.receiveSnapshot = receiveSnapshot
        self.generation = generation
    }

    func requestExtensionManifest(reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            reply(try CMUXSidebarXPCCodec.encodeManifest(manifest), nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func sidebarSnapshotDidChange(_ payload: NSData) {
        receiveSnapshot(payload, generation)
    }
}
