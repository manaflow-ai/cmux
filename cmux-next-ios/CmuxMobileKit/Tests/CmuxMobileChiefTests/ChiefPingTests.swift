import Foundation
import Testing
@testable import CmuxMobileChief

/// The Cloud Chief keepalive ping. URLSession can call a ping's pong handler
/// more than once while a socket tears down; cmux INTERNAL 1.2.0
/// (20261020003123) crashed twice on 2026-10-19 with "continuation resumed
/// twice" on the NSURLSession delegate queue from this ping.
@Suite struct ChiefPingTests {
    @Test func aPongReportsTheSocketAlive() async {
        #expect(await ChiefCloudBackend.Core.ping(using: { pong in pong(nil) }))
    }

    @Test func aFailedPingReportsTheSocketDead() async {
        #expect(await !ChiefCloudBackend.Core.ping(using: { pong in pong(URLError(.networkConnectionLost)) }))
    }

    @Test func aSecondPongDuringTeardownIsIgnored() async {
        let alive = await ChiefCloudBackend.Core.ping(using: { pong in
            pong(nil)
            pong(URLError(.cancelled))
        })
        #expect(alive)
    }

    @Test func pongsRacingOnTwoQueuesResumeOnce() async {
        for _ in 0..<200 {
            _ = await ChiefCloudBackend.Core.ping(using: { pong in
                DispatchQueue.global().async { pong(nil) }
                DispatchQueue.global().async { pong(URLError(.cancelled)) }
            })
        }
    }
}
