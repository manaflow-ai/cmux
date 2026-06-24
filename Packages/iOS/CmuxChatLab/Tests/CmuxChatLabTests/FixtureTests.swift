import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxChatLab

struct FixtureTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000)

    @Test func resolveFallsBackToWrapping() {
        #expect(ChatLabFixture.resolve(nil) == .wrapping)
        #expect(ChatLabFixture.resolve("bogus") == .wrapping)
        #expect(ChatLabFixture.resolve("history-10k") == .history10k)
    }

    @Test func everyFixtureProducesMessagesWithStableIDs() {
        for fixture in ChatLabFixture.allCases {
            let scenario = fixture.scenario(now: now)
            #expect(!scenario.backlog.isEmpty, "\(fixture) should not be empty")
            let ids = Set(scenario.backlog.map(\.id))
            #expect(ids.count == scenario.backlog.count, "\(fixture) has duplicate ids")
        }
    }

    @Test func seqIsMonotonic() {
        for fixture in ChatLabFixture.allCases {
            let backlog = fixture.scenario(now: now).backlog
            for (lhs, rhs) in zip(backlog, backlog.dropFirst()) {
                #expect(rhs.seq > lhs.seq, "\(fixture) seq must increase")
            }
        }
    }

    @Test func historyFixtureIsLarge() {
        #expect(ChatLabFixture.history10k.scenario(now: now).backlog.count == 10_000)
    }

    @Test func paginateWindowIsSmallerThanBacklog() {
        let scenario = ChatLabFixture.paginate.scenario(now: now)
        #expect(scenario.pageSize < scenario.backlog.count)
    }

    @Test func mediaFixtureCarriesImageAttachments() {
        let backlog = ChatLabFixture.media.scenario(now: now).backlog
        let attachments = backlog.compactMap { message -> ChatAttachment? in
            if case let .attachment(attachment) = message.kind { return attachment }
            return nil
        }
        #expect(attachments.count == 3)
        #expect(attachments.allSatisfy { $0.media == .image })
        #expect(attachments.allSatisfy { ($0.hostPath ?? "").hasPrefix("\(ChatLabFixture.mediaScheme):") })
    }
}
