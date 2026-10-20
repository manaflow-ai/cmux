import CmuxNextCloud
import Testing

@MainActor
@Suite struct CloudSessionLifecycleTests {
    @Test(arguments: [false, true])
    func aNewSessionRetiresTheOldResourcesEvenWhenSignedInStaysTrue(sameAccount: Bool) async {
        let world = CloudSessionLifecycleWorld()
        let a = world.choose("a", generation: 1)
        await world.lifecycle.update(a).value
        let b = world.choose(sameAccount ? "a" : "b", generation: 2)
        await world.lifecycle.update(b).value
        #expect(world.live == b)
        #expect(world.events.suffix(3) == ["retire", "begin \(b.accountID):2", "ready \(b.accountID):2"])
        await world.lifecycle.stop().value
    }

    @Test func aReplacementDuringSignOutStartsOnlyAfterTheBarrierReleases() async {
        let world = CloudSessionLifecycleWorld()
        await world.lifecycle.update(world.choose("a", generation: 1)).value
        await world.lifecycle.suspend().value
        let b = world.choose("b", generation: 2)
        await world.lifecycle.update(b).value
        #expect(world.live == nil)
        #expect(!world.events.contains("begin b:2"))
        await world.lifecycle.resume(b).value
        #expect(world.live == b)
        #expect(world.events.suffix(2) == ["begin b:2", "ready b:2"])
        await world.lifecycle.stop().value
    }

    @Test func aHeldStartupJoinsBeforeAnotherSessionStarts() async {
        let world = CloudSessionLifecycleWorld()
        let a = world.choose("a", generation: 1)
        world.holdStart()
        let first = world.lifecycle.update(a)
        await world.waitUntilHeld()
        let b = world.choose("b", generation: 2)
        let second = world.lifecycle.update(b)
        #expect(!world.events.contains("begin b:2"))
        world.release()
        await first.value; await second.value
        #expect(world.live == b)
        #expect(world.events.suffix(4) == ["refused a:1", "retire", "begin b:2", "ready b:2"])
        await world.lifecycle.stop().value
    }

    @Test func quitJoinsAStartupAndCannotReopenOnALaterUpdate() async {
        let world = CloudSessionLifecycleWorld()
        let a = world.choose("a", generation: 1)
        world.holdStart()
        let starting = world.lifecycle.update(a)
        await world.waitUntilHeld()
        let stopping = world.lifecycle.stop()
        world.release()
        await starting.value; await stopping.value
        await world.lifecycle.resume(world.choose("b", generation: 2)).value
        #expect(world.live == nil)
        #expect(world.events.suffix(2) == ["refused a:1", "quit"])
    }

    @Test func repeatingTheSameIdentityReusesItAndPolicyRefreshIsExplicit() async {
        let world = CloudSessionLifecycleWorld()
        let a = world.choose("a", generation: 1)
        await world.lifecycle.update(a).value
        let before = world.events
        await world.lifecycle.update(a).value
        #expect(world.events == before)
        await world.lifecycle.refresh(a).value
        #expect(world.events.suffix(2) == ["begin a:1", "ready a:1"])
        await world.lifecycle.stop().value
    }
}
