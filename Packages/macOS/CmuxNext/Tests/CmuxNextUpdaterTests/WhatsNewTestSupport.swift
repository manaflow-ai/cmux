import Foundation
@testable import CmuxNextUpdater

/// Shared What's New fixtures: the repository's validator fixture (the same
/// file `scripts/whats-new/test_validate.py` passes) and small documents.
nonisolated struct WhatsNewFixtures {
    /// scripts/whats-new/fixtures/good/1.0.0-nightly.42.json in this checkout.
    static var sharedFixtureURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }  // Packages/macOS/CmuxNext/Tests/CmuxNextUpdaterTests/<file> -> repo root
        return url.appending(path: "scripts/whats-new/fixtures/good/1.0.0-nightly.42.json")
    }

    static func document(_ version: String, channel: WhatsNewDocument.Channel = .stable, entries: Int = 1,
                         origin: WhatsNewDocument.Origin = .bundled) -> WhatsNewDocument {
        WhatsNewDocument(version: version, channel: channel, date: "2026-10-07", headline: WhatsNewText(stringLiteral: "Headline \(version)"),
                         entries: (0..<entries).map { index in
                             WhatsNewDocument.Entry(id: "entry-\(index)", category: .new, title: WhatsNewText(stringLiteral: "Entry \(index) of \(version)"),
                                                    summary: "A summary.", tryIt: WhatsNewDocument.TryIt(action: "home.show"))
                         }, origin: origin)
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "whats-new-\(UUID().uuidString)")!  // crash-allow: a fresh suite name always opens in tests
    }
}

/// A source that answers from memory and records what it was asked.
nonisolated final class StubWhatsNewSource: WhatsNewSource, @unchecked Sendable {
    let stored: [WhatsNewDocument]
    let readsNetwork: Bool
    private(set) var asked: [WhatsNewVersion?] = []

    init(_ documents: [WhatsNewDocument], readsNetwork: Bool = false) {
        stored = documents
        self.readsNetwork = readsNetwork
    }

    func documents(after: WhatsNewVersion?, through: WhatsNewVersion) async -> [WhatsNewDocument] {
        asked.append(after)
        return stored.filter { document in
            guard let version = document.parsedVersion else { return false }
            return version <= through && (after.map { $0 < version } ?? true)
        }
    }
}
