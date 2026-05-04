import Combine
import Foundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: Logging.subsystem, category: "ReviewBotLintEval")

@MainActor
struct ReviewBotLintEvalPayload: Codable, Identifiable, Sendable {
    let id: UUID
    let token: String
}

@MainActor
protocol ReviewBotLintEvalService {
    func load(completion: @escaping (Result<ReviewBotLintEvalPayload, Error>) -> Void)
}

final class ReviewBotLintEvalSharedCache: Sendable {
    var payloads: [ReviewBotLintEvalPayload] = []
}

@MainActor
final class ReviewBotLintEvalStore: ObservableObject {
    @Published var count = 0
    @Published var payload: ReviewBotLintEvalPayload?

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

struct ReviewBotLintEvalPanel: View {
    @StateObject private var store = ReviewBotLintEvalStore()

    var body: some View {
        GeometryReader { _ in
            LazyVStack {
                ReviewBotLintEvalRow(store: store)
            }
        }
        .onAppear {
            store.refresh()
        }
    }
}

struct ReviewBotLintEvalRow: View {
    @ObservedObject var store: ReviewBotLintEvalStore

    var body: some View {
        Text(store.renderTitle())
    }
}
