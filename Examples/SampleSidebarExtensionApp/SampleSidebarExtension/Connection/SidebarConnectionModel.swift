import Foundation
import Observation
import SwiftUI
import CmuxExtensionKit

@Observable
final class SidebarConnectionModel: @unchecked Sendable {
    static let shared = SidebarConnectionModel()
    static let manifest = CMUXExtensionManifest(
        id: "co.manaflow.CMUXExtKitSampleSidebarApp.Extension",
        displayName: "CMUX Sample Sidebar Extension",
        requestedScopes: [
            .workspaceMetadata,
            .workspacePaths,
            .notifications,
            .networkPorts,
            .pullRequests,
        ],
        requestedActionScopes: [
            .selectWorkspace,
        ]
    )

    private(set) var snapshot: CMUXSidebarSnapshot?
    private(set) var errorText: String?

    @ObservationIgnored
    private var connection: NSXPCConnection?

    @ObservationIgnored
    private var connectionGeneration: UInt64 = 0

    @ObservationIgnored
    private var host: CMUXSidebarHostXPC?

    private init() {}

    func accept(connection: NSXPCConnection) -> Bool {
        self.connection?.invalidate()
        connectionGeneration += 1
        let generation = connectionGeneration
        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.exportedObject = SidebarExtensionXPCReceiver(model: self, generation: generation)
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        connection.invalidationHandler = { [weak self] in
            guard let model = self else { return }
            Task { @MainActor [model, generation] in
                model.clearConnection(ifCurrentGeneration: generation)
            }
        }
        connection.interruptionHandler = { [weak self] in
            guard let model = self else { return }
            Task { @MainActor [model, generation] in
                guard model.connectionGeneration == generation else { return }
                model.host = nil
                model.errorText = String(localized: "sampleSidebar.waitingForHost", defaultValue: "Waiting for cmux")
            }
        }
        self.connection = connection
        host = connection.remoteObjectProxyWithErrorHandler { [weak self, generation] error in
            guard let model = self else { return }
            let message = error.localizedDescription
            Task { @MainActor [model, generation] in
                guard model.connectionGeneration == generation else { return }
                model.errorText = message
            }
        } as? CMUXSidebarHostXPC
        connection.resume()
        refreshSnapshot()
        return true
    }

    var insights: SidebarInsightModel? {
        snapshot.map(SidebarInsightModel.init(snapshot:))
    }

    func refreshSnapshot() {
        guard let host else {
            errorText = String(localized: "sampleSidebar.waitingForHost", defaultValue: "Waiting for cmux")
            return
        }
        let generation = connectionGeneration
        host.requestSidebarSnapshot { [weak self] payload, error in
            guard let model = self else { return }
            let payload = payload.map { $0 as Data }
            let error = error.map { String($0) }
            Task { @MainActor [model, generation] in
                guard model.connectionGeneration == generation else { return }
                if let error {
                    model.errorText = error
                    return
                }
                guard let payload else {
                    model.errorText = String(localized: "sampleSidebar.emptySnapshot", defaultValue: "cmux did not send a workspace snapshot")
                    return
                }
                do {
                    model.snapshot = try CMUXSidebarXPCCodec.decodeSnapshot(payload as NSData)
                    model.errorText = nil
                } catch {
                    model.errorText = error.localizedDescription
                }
            }
        }
    }

    func selectWorkspace(_ id: UUID) {
        send(.selectWorkspace(id))
    }

    private func send(_ action: CMUXSidebarAction) {
        guard let host else { return }
        let generation = connectionGeneration
        do {
            let payload = try CMUXSidebarXPCCodec.encodeAction(action)
            host.performSidebarAction(payload) { [weak self] resultPayload, error in
                guard let model = self else { return }
                let resultPayload = resultPayload.map { $0 as Data }
                let error = error.map { String($0) }
                Task { @MainActor [model, generation] in
                    guard model.connectionGeneration == generation else { return }
                    if let error {
                        model.errorText = error
                        return
                    }
                    if let resultPayload {
                        let result = try? CMUXSidebarXPCCodec.decodeActionResult(resultPayload as NSData)
                        if result?.accepted == false {
                            model.errorText = result?.message
                        }
                    }
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    fileprivate func receive(snapshot payload: Data, ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        do {
            snapshot = try CMUXSidebarXPCCodec.decodeSnapshot(payload as NSData)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clearConnection(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        connection = nil
        host = nil
        errorText = String(localized: "sampleSidebar.waitingForHost", defaultValue: "Waiting for cmux")
    }
}

private final class SidebarExtensionXPCReceiver: NSObject, CMUXSidebarExtensionXPC {
    weak var model: SidebarConnectionModel?
    let generation: UInt64

    init(model: SidebarConnectionModel, generation: UInt64) {
        self.model = model
        self.generation = generation
    }

    func sidebarSnapshotDidChange(_ payload: NSData) {
        let payload = payload as Data
        let model = model
        let generation = generation
        Task { @MainActor in
            model?.receive(snapshot: payload, ifCurrentGeneration: generation)
        }
    }

    func requestExtensionManifest(reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            reply(try CMUXSidebarXPCCodec.encodeManifest(SidebarConnectionModel.manifest), nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }
}
