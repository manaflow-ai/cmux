import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the composer's pending-attachment store logic
/// (add/remove/clear, per-terminal keying, send-enabled gating). The actual
/// image RPC and the post-ack text reconciliation are covered elsewhere; these
/// drive the staging state directly, which is what the composer's chip row and
/// Send gating read.
@MainActor
@Suite struct ComposerPendingAttachmentTests {
    private static let terminalA = MobileTerminalPreview(id: "term-a", name: "a")
    private static let terminalB = MobileTerminalPreview(id: "term-b", name: "b")

    /// A composite selected on `term-a`. Selection is set by `init` (no `didSet`
    /// draft swap fires), so the store contents stay exactly what each test seeds.
    private static func makeComposite() -> MobileShellComposite {
        MobileShellComposite(
            workspaces: [
                MobileWorkspacePreview(id: "ws-1", name: "ws", terminals: [terminalA, terminalB]),
            ]
        )
    }

    private static func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func addAppendsInPickOrder() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("one"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("two"), format: "jpg", forTerminalID: "term-a")

        let staged = composite.pendingAttachments(forTerminalID: "term-a")
        #expect(staged.count == 2)
        #expect(staged[0].data == Self.bytes("one"))
        #expect(staged[0].format == "png")
        #expect(staged[1].data == Self.bytes("two"))
        #expect(staged[1].format == "jpg")
    }

    @Test func addIgnoresEmptyData() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Data(), format: "png", forTerminalID: "term-a")
        #expect(composite.pendingAttachments(forTerminalID: "term-a").isEmpty)
    }

    @Test func removeDropsOnlyTheTargetedAttachment() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("one"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("two"), format: "png", forTerminalID: "term-a")
        let toRemove = composite.pendingAttachments(forTerminalID: "term-a")[0].id

        composite.removePendingAttachment(id: toRemove, forTerminalID: "term-a")

        let staged = composite.pendingAttachments(forTerminalID: "term-a")
        #expect(staged.count == 1)
        #expect(staged[0].data == Self.bytes("two"))
    }

    @Test func clearEmptiesOnlyTheGivenTerminal() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("a1"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("b1"), format: "png", forTerminalID: "term-b")

        composite.clearPendingAttachments(forTerminalID: "term-a")

        #expect(composite.pendingAttachments(forTerminalID: "term-a").isEmpty)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").count == 1)
    }

    @Test func attachmentsAreKeyedPerTerminal() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("a1"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("b1"), format: "png", forTerminalID: "term-b")
        composite.addPendingAttachment(Self.bytes("b2"), format: "png", forTerminalID: "term-b")

        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").count == 2)
    }

    @Test func defaultsToSelectedTerminalWhenIDOmitted() {
        let composite = Self.makeComposite()
        // Selected terminal is term-a (set at init).
        composite.addPendingAttachment(Self.bytes("sel"), format: "png")
        #expect(composite.pendingAttachments().count == 1)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").isEmpty)
    }

    @Test func canSendWhenTextEmptyButAttachmentPresent() {
        let composite = Self.makeComposite()
        composite.terminalInputText = ""
        #expect(composite.composerCanSend(forTerminalID: "term-a") == false)

        composite.addPendingAttachment(Self.bytes("img"), format: "png", forTerminalID: "term-a")
        #expect(composite.composerCanSend(forTerminalID: "term-a") == true)
    }

    @Test func canSendWhenTextPresentButNoAttachment() {
        let composite = Self.makeComposite()
        composite.terminalInputText = "hello"
        #expect(composite.composerCanSend(forTerminalID: "term-a") == true)
    }

    @Test func cannotSendWhenTextWhitespaceAndNoAttachment() {
        let composite = Self.makeComposite()
        composite.terminalInputText = "   \n  "
        #expect(composite.composerCanSend(forTerminalID: "term-a") == false)
    }

    @Test func signOutClearsPendingAttachments() {
        let composite = Self.makeComposite()
        // A previous account stages photo bytes on two terminals.
        composite.addPendingAttachment(Self.bytes("a-img"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("b-img"), format: "png", forTerminalID: "term-b")

        // Sign-out is the account-bound reset that wipes the previous user's
        // unsent content (text drafts, etc.); the staged photo bytes must go too
        // so a reused terminal id under the next account never resurfaces them.
        composite.signOut()

        #expect(composite.pendingAttachments(forTerminalID: "term-a").isEmpty)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").isEmpty)
    }

    @Test func guardedAddDroppedAfterSignOutGenerationBump() {
        let composite = Self.makeComposite()
        // The picker captures the session token before its (async) load+encode.
        let captured = composite.currentSessionGeneration

        // A sign-out lands while the photo is in flight, wiping staged content and
        // bumping the session token.
        composite.signOut()

        // The continuation now tries to stage the previous user's bytes. The
        // guarded add must drop it: the captured token no longer matches.
        let id = composite.addPendingAttachment(
            Self.bytes("prev-user-photo"),
            format: "png",
            forTerminalID: "term-a",
            ifSessionGeneration: captured
        )
        #expect(id == nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").isEmpty)
    }

    @Test func guardedAddSucceedsWhenSessionUnchanged() {
        let composite = Self.makeComposite()
        let captured = composite.currentSessionGeneration
        // No sign-out: the token still matches, so the photo stages normally.
        let id = composite.addPendingAttachment(
            Self.bytes("photo"),
            format: "png",
            forTerminalID: "term-a",
            ifSessionGeneration: captured
        )
        #expect(id != nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
    }

    @Test func guardedAddDroppedWhenTargetTerminalGone() {
        let composite = Self.makeComposite()
        let captured = composite.currentSessionGeneration
        // The captured terminal no longer exists in the current workspaces, so
        // the photo must not accrue orphaned bytes under a dead id.
        let id = composite.addPendingAttachment(
            Self.bytes("photo"),
            format: "png",
            forTerminalID: "term-gone",
            ifSessionGeneration: captured
        )
        #expect(id == nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-gone").isEmpty)
    }

    // MARK: - Topology validation and pruning (no orphaned bytes for stale ids)

    /// The BASE add path (no session token) must also reject a terminal id that
    /// is not in the current topology, so there is no unchecked entry point that
    /// can accrue orphaned photo bytes under a dead id.
    @Test func baseAddDroppedWhenTerminalNotInTopology() {
        let composite = Self.makeComposite()
        let id = composite.addPendingAttachment(
            Self.bytes("photo"),
            format: "png",
            forTerminalID: "term-gone"
        )
        #expect(id == nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-gone").isEmpty)
    }

    /// When a topology sync drops a terminal, its staged attachments must be
    /// released in memory (they hold multi-MB `Data`), not retained until
    /// sign-out. The surviving terminal's attachments stay intact.
    @Test func topologyUpdateDroppingTerminalPrunesItsAttachments() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("a-img"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("b-img"), format: "png", forTerminalID: "term-b")
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").count == 1)

        // A workspace sync now reports only term-a (term-b was closed). Setting
        // `workspaces` is the single topology funnel; its `didSet` must prune the
        // staged bytes for the terminal that disappeared.
        composite.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(id: "ws-1", name: "ws", terminals: [Self.terminalA]),
        ])

        #expect(composite.pendingAttachments(forTerminalID: "term-b").isEmpty)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
    }

    /// A terminal removed from one workspace but present in another stays staged:
    /// pruning keys on the terminal id's presence anywhere in topology, not on
    /// which workspace holds it.
    @Test func topologyUpdateKeepsTerminalStillPresentElsewhere() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("b-img"), format: "png", forTerminalID: "term-b")

        // term-b moves to a second workspace; it is still in topology, so its
        // attachments survive.
        composite.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(id: "ws-1", name: "ws", terminals: [Self.terminalA]),
            MobileWorkspacePreview(id: "ws-2", name: "ws2", terminals: [Self.terminalB]),
        ])

        #expect(composite.pendingAttachments(forTerminalID: "term-b").count == 1)
    }

    // MARK: - Atomic count / byte caps (store is the authoritative budget)

    /// Bytes of the given length, distinct per call so attachments are unique.
    private static func bytes(count: Int, fill: UInt8) -> Data {
        Data(repeating: fill, count: count)
    }

    @Test func addRejectsBeyondCountCap() {
        let composite = Self.makeComposite()
        let cap = MobileShellComposite.maxPendingAttachmentCount
        // Fill exactly to the cap; every add up to it succeeds.
        for i in 0..<cap {
            let id = composite.addPendingAttachment(Self.bytes("img-\(i)"), format: "png", forTerminalID: "term-a")
            #expect(id != nil)
        }
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == cap)

        // The next add is over the cap and must be rejected without growing the set.
        let overflow = composite.addPendingAttachment(Self.bytes("over"), format: "png", forTerminalID: "term-a")
        #expect(overflow == nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == cap)
    }

    @Test func addRejectsBeyondTotalByteBudget() {
        let composite = Self.makeComposite()
        let budget = MobileShellComposite.maxPendingAttachmentTotalBytes
        // A single image just under the per-image cap, staged a few times to
        // approach the total budget. 4 MB each, under the 8 MB per-image cap.
        let chunk = 4 * 1024 * 1024
        var staged = 0
        var fill: UInt8 = 1
        while staged + chunk <= budget {
            let id = composite.addPendingAttachment(
                Self.bytes(count: chunk, fill: fill),
                format: "jpg",
                forTerminalID: "term-a"
            )
            #expect(id != nil)
            staged += chunk
            fill &+= 1
        }
        // The remaining headroom is now smaller than one more chunk: that add
        // exceeds the budget and must be rejected, leaving the set unchanged.
        let countBefore = composite.pendingAttachments(forTerminalID: "term-a").count
        let overflow = composite.addPendingAttachment(
            Self.bytes(count: chunk, fill: 0xFF),
            format: "jpg",
            forTerminalID: "term-a"
        )
        #expect(overflow == nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == countBefore)
    }

    @Test func addRejectsSingleImageOverPerImageCap() {
        let composite = Self.makeComposite()
        let perImage = MobileShellComposite.maxPendingAttachmentImageBytes
        let id = composite.addPendingAttachment(
            Self.bytes(count: perImage + 1, fill: 7),
            format: "png",
            forTerminalID: "term-a"
        )
        #expect(id == nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").isEmpty)
    }

    /// Two batches that each snapshot the SAME starting budget and then interleave
    /// their adds must not both append past the count cap: because the cap is
    /// enforced against the current staged set at each add (atomic on @MainActor),
    /// the combined total stops exactly at the cap. This is the concurrent-picker
    /// race from finding 2 reduced to its store-mutation core.
    @Test func racingAddsCannotExceedCountCap() {
        let composite = Self.makeComposite()
        let cap = MobileShellComposite.maxPendingAttachmentCount
        // Both "batches" captured an empty starting set; each tries to add `cap`
        // items, interleaved. Only `cap` total may land.
        var accepted = 0
        for i in 0..<cap {
            if composite.addPendingAttachment(Self.bytes("a-\(i)"), format: "png", forTerminalID: "term-a") != nil {
                accepted += 1
            }
            if composite.addPendingAttachment(Self.bytes("b-\(i)"), format: "png", forTerminalID: "term-a") != nil {
                accepted += 1
            }
        }
        #expect(accepted == cap)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == cap)
    }

    /// The byte budget is likewise atomic against racing adds: two batches sized to
    /// each fit alone but to overflow together cannot both fully land.
    @Test func racingAddsCannotExceedByteBudget() {
        let composite = Self.makeComposite()
        let budget = MobileShellComposite.maxPendingAttachmentTotalBytes
        // Each chunk is 4 MB; budget/4MB = 8 chunks fit. Two batches each try to
        // add 8 chunks interleaved; only 8 total may land.
        let chunk = 4 * 1024 * 1024
        let fits = budget / chunk
        var accepted = 0
        var fill: UInt8 = 1
        for _ in 0..<fits {
            if composite.addPendingAttachment(Self.bytes(count: chunk, fill: fill), format: "jpg", forTerminalID: "term-a") != nil {
                accepted += 1
            }
            fill &+= 1
            if composite.addPendingAttachment(Self.bytes(count: chunk, fill: fill), format: "jpg", forTerminalID: "term-a") != nil {
                accepted += 1
            }
            fill &+= 1
        }
        #expect(accepted == fits)
        let total = composite.pendingAttachments(forTerminalID: "term-a").reduce(0) { $0 + $1.data.count }
        #expect(total <= budget)
    }

    /// The guarded (session-generation) add path enforces the same caps, since it
    /// funnels through the base add after its generation/terminal checks.
    @Test func guardedAddAlsoEnforcesCountCap() {
        let composite = Self.makeComposite()
        let captured = composite.currentSessionGeneration
        let cap = MobileShellComposite.maxPendingAttachmentCount
        for i in 0..<cap {
            _ = composite.addPendingAttachment(Self.bytes("g-\(i)"), format: "png", forTerminalID: "term-a", ifSessionGeneration: captured)
        }
        let overflow = composite.addPendingAttachment(
            Self.bytes("g-over"),
            format: "png",
            forTerminalID: "term-a",
            ifSessionGeneration: captured
        )
        #expect(overflow == nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == cap)
    }

    // MARK: - Global (all-terminals) caps

    /// A composite whose single workspace holds `count` terminals (term-0 ...),
    /// so a test can spread staged attachments across many terminals to drive the
    /// GLOBAL budget while each terminal stays under its own per-terminal cap.
    private static func makeMultiTerminalComposite(terminalCount: Int) -> MobileShellComposite {
        let terminals = (0..<terminalCount).map { i in
            MobileTerminalPreview(id: MobileTerminalPreview.ID(rawValue: "term-\(i)"), name: "t\(i)")
        }
        return MobileShellComposite(
            workspaces: [MobileWorkspacePreview(id: "ws-1", name: "ws", terminals: terminals)]
        )
    }

    /// Staging across many terminals must stop at the GLOBAL byte budget even
    /// though every individual terminal stays under its own per-terminal cap:
    /// without the global cap the all-terminals total grows linearly with
    /// terminal count and can OOM. One 4 MB image per terminal keeps each terminal
    /// far under its 32 MB per-terminal budget, so only the global cap can bind.
    @Test func globalByteBudgetRejectsAcrossManyTerminalsEachUnderPerTerminalCap() {
        let globalBudget = MobileShellComposite.maxPendingAttachmentTotalBytesAllTerminals
        let chunk = 4 * 1024 * 1024
        let fits = globalBudget / chunk
        // Enough terminals to overflow the global budget with one image each.
        let composite = Self.makeMultiTerminalComposite(terminalCount: fits + 2)

        var accepted = 0
        var fill: UInt8 = 1
        for i in 0..<(fits + 2) {
            // Each terminal gets exactly one 4 MB image: per-terminal byte cap
            // (32 MB) and per-terminal count cap (10) are never the binding limit.
            let id = composite.addPendingAttachment(
                Self.bytes(count: chunk, fill: fill),
                format: "jpg",
                forTerminalID: "term-\(i)"
            )
            if id != nil { accepted += 1 }
            fill &+= 1
        }

        // Only as many as the global budget allows landed.
        #expect(accepted == fits)
        var globalBytes = 0
        for i in 0..<(fits + 2) {
            globalBytes += composite.pendingAttachments(forTerminalID: "term-\(i)").reduce(0) { $0 + $1.data.count }
        }
        #expect(globalBytes <= globalBudget)
    }

    /// Staging across many terminals must also stop at the GLOBAL count budget,
    /// independent of bytes: tiny images spread one-per-terminal stay under every
    /// per-terminal count cap (10) yet must be rejected once the all-terminals
    /// total reaches the global count cap.
    @Test func globalCountBudgetRejectsAcrossManyTerminalsEachUnderPerTerminalCap() {
        let globalCount = MobileShellComposite.maxPendingAttachmentCountAllTerminals
        let composite = Self.makeMultiTerminalComposite(terminalCount: globalCount + 3)

        var accepted = 0
        for i in 0..<(globalCount + 3) {
            // One tiny image per terminal: per-terminal count cap (10) never binds.
            let id = composite.addPendingAttachment(Self.bytes("img-\(i)"), format: "png", forTerminalID: "term-\(i)")
            if id != nil { accepted += 1 }
        }

        #expect(accepted == globalCount)
        var total = 0
        for i in 0..<(globalCount + 3) {
            total += composite.pendingAttachments(forTerminalID: "term-\(i)").count
        }
        #expect(total == globalCount)
    }

    /// The per-terminal caps still bind independently of the global cap: a single
    /// terminal cannot exceed its own count cap even when the global budget has
    /// ample headroom.
    @Test func perTerminalCountCapStillBindsUnderGlobalHeadroom() {
        let composite = Self.makeComposite()
        let perTerminalCap = MobileShellComposite.maxPendingAttachmentCount
        // Global count cap (20) > per-terminal cap (10), so the global cap has
        // headroom; the per-terminal cap must still reject the 11th add.
        for i in 0..<perTerminalCap {
            #expect(composite.addPendingAttachment(Self.bytes("img-\(i)"), format: "png", forTerminalID: "term-a") != nil)
        }
        let overflow = composite.addPendingAttachment(Self.bytes("over"), format: "png", forTerminalID: "term-a")
        #expect(overflow == nil)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == perTerminalCap)
    }

    @Test func submitKeepsAttachmentsWhenSendFails() async {
        let composite = Self.makeComposite()
        // No remoteClient is wired, so the image send fails (returns false). A
        // failed send must KEEP the staged attachments so the user can retry,
        // matching the text-keep-on-failure semantics of submitComposerInput().
        composite.addPendingAttachment(Self.bytes("img"), format: "png", forTerminalID: "term-a")
        composite.terminalInputText = ""

        await composite.submitComposer()

        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
    }
}
