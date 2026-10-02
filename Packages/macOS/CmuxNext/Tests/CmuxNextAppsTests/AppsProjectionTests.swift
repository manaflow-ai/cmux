import Testing
@testable import CmuxNextApps

/// The install projection (mirror + intent log) against a reference owner:
/// random intents, owner commits and refusals in random order, replies and
/// list snapshots delivered out of order. When the log is empty and the
/// newest list landed, the visible state equals the owner's (invariant 4).
struct AppsProjectionTests {
    private static let base = FakeAppsTransport.sampleRecords()

    @Test func anIntentShowsAtOnceAndLeavesOnItsReply() throws {
        var projection = AppsProjection()
        projection.applyList(Self.base, revision: 1)
        let id = "cmux/github-prs"
        projection.enqueue(AppIntent(id: "k1", app: id, change: .install(true), origin: .user))
        #expect(projection.visible(id)?.installed == true)
        #expect(projection.mirror.first { $0.id == id }?.installed == false)
        var committed = try #require(Self.base.first { $0.id == id })
        committed.installed = true
        projection.confirm("k1", record: committed)
        #expect(projection.pending.isEmpty)
        #expect(projection.visible(id) == committed)
    }

    @Test func aRejectReturnsTheAppToTheMirror() {
        var projection = AppsProjection()
        projection.applyList(Self.base, revision: 1)
        let id = "cmux/agent-status"
        let before = projection.visible(id)
        projection.enqueue(AppIntent(id: "k1", app: id, change: .hide(true), origin: .mcp))
        #expect(projection.visible(id)?.hidden == true)
        projection.reject("k1")
        #expect(projection.visible(id) == before)
    }

    @Test func aStaleListIsIgnored() {
        var projection = AppsProjection()
        projection.applyList(Self.base, revision: 5)
        var older = Self.base
        older[0].hidden = true
        projection.applyList(older, revision: 4)
        #expect(projection.mirror == Self.base)
        #expect(projection.revision == 5)
    }

    @Test func removalClearsHideAndGrantsInTheProjection() throws {
        let record = try #require(Self.base.first { $0.isDefault })
        var hidden = record
        hidden.hidden = true
        let removed = AppChange.install(false).applied(to: hidden)
        #expect(!removed.installed && !removed.hidden && removed.grants.isEmpty)
    }

    /// One random run: the owner applies intents in a random order, refuses
    /// some, and the client sees replies and snapshots in a random order.
    @Test(arguments: 0..<200)
    func convergesToTheOwnerForRandomOrders(seed: Int) throws {
        var rng = SeededGenerator(seed: UInt64(seed))
        var owner = Dictionary(uniqueKeysWithValues: Self.base.map { ($0.id, $0) })
        let order = Self.base.map(\.id)
        var revision: UInt64 = 1
        var projection = AppsProjection()
        projection.applyList(Self.base, revision: revision)

        var unprocessed: [AppIntent] = []
        var replies: [Reply] = []
        let changes: [AppChange] = [.install(true), .install(false), .enable(false), .enable(true), .hide(true), .hide(false),
                                    .sandbox(true), .sandbox(false), .grant("actions:run", false), .grant("actions:run", true)]

        for step in 0..<40 {
            switch Int.random(in: 0..<4, using: &rng) {
            case 0, 1:
                let intent = AppIntent(id: "k\(step)", app: order.randomElement(using: &rng)!, change: changes.randomElement(using: &rng)!,
                                       origin: .user)
                projection.enqueue(intent)
                unprocessed.append(intent)
                let visible = try #require(projection.visible(intent.app))
                #expect(visible == projection.pending.filter { $0.app == intent.app }.reduce(projection.mirror.first { $0.id == intent.app }!) {
                    $1.change.applied(to: $0)
                })
            case 2 where !unprocessed.isEmpty:
                let intent = unprocessed.remove(at: Int.random(in: 0..<unprocessed.count, using: &rng))
                if Bool.random(using: &rng) {
                    owner[intent.app] = intent.change.applied(to: owner[intent.app]!)
                    revision += 1
                    replies.append(.confirm(intent.id, owner[intent.app]!))
                    replies.append(.list(order.map { owner[$0]! }, revision))
                } else {
                    replies.append(.reject(intent.id))
                }
            default:
                guard !replies.isEmpty else { continue }
                Self.deliver(replies.remove(at: Int.random(in: 0..<replies.count, using: &rng)), to: &projection)
            }
        }
        // The owner settles every remaining intent; every reply arrives.
        for intent in unprocessed.shuffled(using: &rng) {
            owner[intent.app] = intent.change.applied(to: owner[intent.app]!)
            revision += 1
            replies.append(.confirm(intent.id, owner[intent.app]!))
        }
        for reply in replies.shuffled(using: &rng) { Self.deliver(reply, to: &projection) }
        // apps-changed for the last commit lists once more.
        projection.applyList(order.map { owner[$0]! }, revision: revision)
        #expect(projection.pending.isEmpty)
        #expect(projection.visible == order.map { owner[$0]! })
    }

    private enum Reply { case confirm(String, AppRecord), reject(String), list([AppRecord], UInt64) }

    private static func deliver(_ reply: Reply, to projection: inout AppsProjection) {
        switch reply {
        case .confirm(let key, let record): projection.confirm(key, record: record)
        case .reject(let key): projection.reject(key)
        case .list(let records, let revision): projection.applyList(records, revision: revision)
        }
    }
}
