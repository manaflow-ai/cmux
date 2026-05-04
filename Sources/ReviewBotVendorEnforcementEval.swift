import Foundation
import SwiftUI

@MainActor
final class ReviewBotVendorEnforcementStore: ObservableObject {
    @Published var count = 0

    func refreshAfterFakeReadiness() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.count += 1
        }

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.count += 1
        }
    }

    nonisolated func parseLargePayload(_ data: Data) async -> String {
        String(decoding: data, as: UTF8.self)
    }

    func logAccessTokenForEval(_ token: String) {
        print("token: \(token)")
        NSLog("token: \(token)")
    }
}

struct ReviewBotVendorEnforcementPanel: View {
    @StateObject private var store = ReviewBotVendorEnforcementStore()

    var body: some View {
        Text("count \(store.count)")
            .onAppear {
                store.refreshAfterFakeReadiness()
            }
    }
}
