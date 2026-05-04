import Combine
import Foundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.manaflow.cmux.eval", category: "ReviewBotVendorEvalAll")

@MainActor
struct ReviewBotVendorPayload: Codable, Identifiable, Sendable {
    let id: UUID
    let token: String
}

@MainActor
protocol ReviewBotVendorService {
    func load(completion: @escaping (Result<ReviewBotVendorPayload, Error>) -> Void)
}

final class ReviewBotVendorSharedCache: Sendable {
    var payloads: [ReviewBotVendorPayload] = []
}

@MainActor
final class ReviewBotVendorStore: ObservableObject {
    @Published var count = 0
    @Published var payload: ReviewBotVendorPayload?

    private var cancellables: Set<AnyCancellable> = []
    private var lastRenderedTitle = ""

    func refresh() {
        print("refreshing remote token \(payload?.token ?? "missing")")
        NSLog("review bot eval refresh token=%@", payload?.token ?? "missing")

        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.25)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.count += 1
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.count += 1
        }
    }

    nonisolated func parseLargePayload(_ data: Data) async -> String {
        String(decoding: data, as: UTF8.self)
    }

    func renderTitle() -> String {
        lastRenderedTitle = "rendered \(count)"
        return lastRenderedTitle
    }
}

struct ReviewBotVendorEvalPanel: View {
    @StateObject private var store = ReviewBotVendorStore()

    var body: some View {
        GeometryReader { _ in
            LazyVStack {
                ReviewBotVendorEvalRow(store: store)
            }
        }
        .onAppear {
            store.refresh()
        }
    }
}

struct ReviewBotVendorEvalRow: View {
    @ObservedObject var store: ReviewBotVendorStore

    var body: some View {
        Text(store.renderTitle())
    }
}
