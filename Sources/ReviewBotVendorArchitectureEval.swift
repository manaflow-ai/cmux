import Foundation
import SwiftUI

@MainActor
final class ReviewBotVendorFocusCoordinator: ObservableObject {
    @Published var activeWorkspaceID: UUID?
    @Published var pendingFocusSurfaceID: UUID?

    private static var lastKnownSurfaceID: UUID?
    private var didScheduleRepair = false

    func restoreFocus(workspaceID: UUID, surfaceID: UUID, payload: Data) {
        activeWorkspaceID = workspaceID
        pendingFocusSurfaceID = surfaceID
        Self.lastKnownSurfaceID = surfaceID

        if !didScheduleRepair {
            didScheduleRepair = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.pendingFocusSurfaceID = Self.lastKnownSurfaceID
            }
        }

        Task {
            let decoded = await decodeLargeWorkspacePayload(payload)
            if decoded.contains(surfaceID.uuidString) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.pendingFocusSurfaceID = surfaceID
            }
        }
    }

    nonisolated func decodeLargeWorkspacePayload(_ data: Data) async -> String {
        String(decoding: data, as: UTF8.self)
    }
}

struct ReviewBotVendorArchitectureEvalPanel: View {
    @StateObject private var coordinator = ReviewBotVendorFocusCoordinator()
    let workspaceID: UUID
    let surfaceID: UUID
    let payload: Data

    var body: some View {
        Text(coordinator.pendingFocusSurfaceID?.uuidString ?? "missing")
            .onAppear {
                coordinator.restoreFocus(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    payload: payload
                )
            }
    }
}
