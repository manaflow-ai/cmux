import Foundation
import Observation
import SwiftUI
import CmuxExtensionKit

@Observable
final class SidebarConnectionModel: @unchecked Sendable {
    static let shared = SidebarConnectionModel()

    private(set) var snapshot: CMUXSidebarSnapshot?
    private(set) var errorText: String?

    @ObservationIgnored
    private var host: CMUXSidebarHostXPC?

    private init() {}

    func accept(connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.exportedObject = SidebarExtensionXPCReceiver(model: self)
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        host = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            guard let model = self else { return }
            let message = error.localizedDescription
            Task { @MainActor in
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
        host.requestSidebarSnapshot { [weak self] payload, error in
            guard let model = self else { return }
            let payload = payload.map { $0 as Data }
            let error = error.map { String($0) }
            Task { @MainActor in
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
        do {
            let payload = try CMUXSidebarXPCCodec.encodeAction(action)
            host.performSidebarAction(payload) { [weak self] resultPayload, error in
                guard let model = self else { return }
                let resultPayload = resultPayload.map { $0 as Data }
                let error = error.map { String($0) }
                Task { @MainActor in
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

    fileprivate func receive(snapshot payload: Data) {
        do {
            snapshot = try CMUXSidebarXPCCodec.decodeSnapshot(payload as NSData)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private final class SidebarExtensionXPCReceiver: NSObject, CMUXSidebarExtensionXPC {
    weak var model: SidebarConnectionModel?

    init(model: SidebarConnectionModel) {
        self.model = model
    }

    func sidebarSnapshotDidChange(_ payload: NSData) {
        let payload = payload as Data
        let model = model
        Task { @MainActor in
            model?.receive(snapshot: payload)
        }
    }
}
