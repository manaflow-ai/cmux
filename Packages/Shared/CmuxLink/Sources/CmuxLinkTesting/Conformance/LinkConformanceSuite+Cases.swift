import CmuxLink
import Foundation

extension LinkConformanceSuite {
    static func reliable(_ stream: String, _ priority: ChannelPriority = .render, budget: Int? = nil) -> ChannelDescriptor {
        ChannelDescriptor(stream: stream, reliability: .reliableOrdered, priority: priority, budgetBytes: budget)
    }

    @Sendable
    func ordering(_ fixture: ConformanceFixture) async throws -> ConformanceOutcome {
        let count: UInt64 = 300
        let (first, firstRemote) = try await fixture.openPair(Self.reliable("ordering/a"))
        let (second, secondRemote) = try await fixture.openPair(Self.reliable("ordering/b", .input))
        for index in 1...count {
            try await first.send(ConformanceFixture.payload("a", index))
            try await second.send(ConformanceFixture.payload("b", index))
            try await firstRemote.send(ConformanceFixture.payload("r", index))
        }
        try fixture.expectInOrder(
            try await fixture.read(firstRemote, count: Int(count), "channel a"), from: 1, prefix: "a"
        )
        try fixture.expectInOrder(
            try await fixture.read(secondRemote, count: Int(count), "channel b"), from: 1, prefix: "b"
        )
        try fixture.expectInOrder(
            try await fixture.read(first, count: Int(count), "host to dialer"), from: 1, prefix: "r"
        )
        return .passed
    }

    @Sendable
    func lossRecovery(_ fixture: ConformanceFixture) async throws -> ConformanceOutcome {
        let total: UInt64 = 200
        let (channel, remote) = try await fixture.openPair(Self.reliable("loss/a"))
        let sender = Task {
            for index in 1...total {
                try await channel.send(ConformanceFixture.payload("l", index))
            }
        }
        let before = try await fixture.read(remote, count: 50, "before the drop")
        guard await harness.dropTransports() else {
            sender.cancel()
            return .skipped("harness cannot drop transports")
        }
        let after = try await fixture.read(remote, count: Int(total) - 50, "after the drop")
        try await sender.value
        try fixture.expectInOrder(before + after, from: 1, prefix: "l")
        try await fixture.waitForLive(fixture.dialer, "dialer reconnects")
        return .passed
    }

    @Sendable
    func reconnectResume(_ fixture: ConformanceFixture) async throws -> ConformanceOutcome {
        let (channel, remote) = try await fixture.openPair(Self.reliable("resume/a"))
        for index in 1...10 as ClosedRange<UInt64> {
            try await channel.send(ConformanceFixture.payload("up", index))
            try await remote.send(ConformanceFixture.payload("down", index))
        }
        try fixture.expectInOrder(try await fixture.read(remote, count: 10, "up 1-10"), from: 1, prefix: "up")
        try fixture.expectInOrder(try await fixture.read(channel, count: 10, "down 1-10"), from: 1, prefix: "down")
        let epoch = await fixture.dialer.currentEpoch

        let states = await fixture.dialer.states()
        let sawReconnect = Task {
            for await state in states {
                if case .reconnecting = state { return true }
            }
            return false
        }
        guard await harness.dropTransports() else {
            sawReconnect.cancel()
            return .skipped("harness cannot drop transports")
        }
        // Sends while reconnecting are retained and replayed.
        for index in 11...20 as ClosedRange<UInt64> {
            try await channel.send(ConformanceFixture.payload("up", index))
            try await remote.send(ConformanceFixture.payload("down", index))
        }
        try fixture.expectInOrder(try await fixture.read(remote, count: 10, "up 11-20"), from: 11, prefix: "up")
        try fixture.expectInOrder(try await fixture.read(channel, count: 10, "down 11-20"), from: 11, prefix: "down")
        guard try await fixture.deadline.run("reconnecting state", { await sawReconnect.value }) else {
            throw fixture.fail("never reported reconnecting")
        }
        try await fixture.waitForLive(fixture.dialer, "dialer live after resume")
        guard await fixture.dialer.currentEpoch == epoch else { throw fixture.fail("resume changed the epoch") }
        guard await fixture.host.activeSessionCount == 1 else { throw fixture.fail("resume created a second session") }

        // A cursor the host cannot serve yields one gap, then fresh data.
        let stale = StreamCursor(stream: "resume/stale", epoch: epoch &+ 7, revision: 5)
        let (resumed, resumedRemote) = try await fixture.openPair(Self.reliable("resume/stale"), resumeFrom: stale)
        try await resumedRemote.send(ConformanceFixture.payload("fresh", 1))
        guard case let .gap(gap)? = try await fixture.nextEvent(resumed, "stale cursor gap") else {
            throw fixture.fail("stale cursor did not report a gap")
        }
        guard gap.lastDelivered == stale, gap.resumedAfter.revision == 0 else {
            throw fixture.fail("gap \(gap) does not name the stale cursor")
        }
        try fixture.expectInOrder(try await fixture.read(resumed, count: 1, "after the gap"), from: 1, prefix: "fresh")
        return .passed
    }

    @Sendable
    func backPressure(_ fixture: ConformanceFixture) async throws -> ConformanceOutcome {
        let chunk = 1024
        let budget = 8 * chunk
        let (channel, remote) = try await fixture.openPair(Self.reliable("pressure/a", budget: budget))
        for index in 1...8 as ClosedRange<UInt64> {
            try await fixture.deadline.run("send \(index) within budget") {
                try await channel.send(Self.chunk(index, size: chunk))
            }
        }
        let ninthSent = AsyncQueue<Bool>()
        let blocked = Task {
            try await channel.send(Self.chunk(9, size: chunk))
            await ninthSent.push(true)
        }
        // The consumer has not read anything: the ninth send must wait.
        try await Task.sleep(for: .milliseconds(150))
        guard await ninthSent.count == 0 else { throw fixture.fail("send exceeded the budget without a consumer") }
        let firstRead = try await fixture.read(remote, count: 1, "first message")
        try await fixture.deadline.run("ninth send after credit") { try await blocked.value }
        let rest = try await fixture.read(remote, count: 8, "remaining messages")
        let all = firstRead + rest
        guard all.map(\.revision) == Array(1...9), all.enumerated().allSatisfy({ $1.payload == Self.chunk(UInt64($0 + 1), size: chunk) }) else {
            throw fixture.fail("back-pressured messages out of order")
        }
        return .passed
    }

    static func chunk(_ index: UInt64, size: Int) -> Data {
        Data(repeating: UInt8(truncatingIfNeeded: index), count: size)
    }

    @Sendable
    func closeSemantics(_ fixture: ConformanceFixture) async throws -> ConformanceOutcome {
        let (channel, remote) = try await fixture.openPair(Self.reliable("close/a"))
        for index in 1...20 as ClosedRange<UInt64> {
            try await channel.send(ConformanceFixture.payload("c", index))
        }
        await channel.close()
        do {
            try await channel.send(Data("late".utf8))
            throw fixture.fail("send after close succeeded")
        } catch LinkError.channelClosed {}
        guard case .closed(.local)? = try await fixture.nextEvent(channel, "local close event") else {
            throw fixture.fail("closed channel did not end with .closed(.local)")
        }
        try fixture.expectInOrder(try await fixture.read(remote, count: 20, "before close"), from: 1, prefix: "c")
        guard case .closed(.remote)? = try await fixture.nextEvent(remote, "remote close event") else {
            throw fixture.fail("peer did not see .closed(.remote) after the data")
        }
        guard try await fixture.nextEvent(remote, "end of events") == nil else {
            throw fixture.fail("events continued after close")
        }

        let (other, otherRemote) = try await fixture.openPair(Self.reliable("close/b"))
        await fixture.dialer.close()
        await fixture.dialer.close()
        guard await fixture.dialer.state == .closed(.local) else { throw fixture.fail("dialer not closed(.local)") }
        do {
            try await other.send(Data("after session close".utf8))
            throw fixture.fail("send after session close succeeded")
        } catch LinkError.closed(.local) {}
        try await fixture.waitFor(fixture.hostSession, "host sees remote close") { $0 == .closed(.remote) }
        guard case .closed(.sessionClosed(.remote))? = try await fixture.nextEvent(otherRemote, "host channel ends") else {
            throw fixture.fail("host channel did not end with the session")
        }
        return .passed
    }

    @Sendable
    func pathChangeMidStream(_ fixture: ConformanceFixture) async throws -> ConformanceOutcome {
        guard let startPath = await fixture.dialer.state.path?.kind else { throw fixture.fail("no path") }
        let target: PathKind = startPath == .turn ? .p2p : .turn
        let total: UInt64 = 120
        let (channel, remote) = try await fixture.openPair(Self.reliable("path/a"))
        let badges = await fixture.dialer.pathBadges()
        let sawTarget = Task {
            for await badge in badges where badge.path.kind == target { return true }
            return false
        }
        let sender = Task {
            for index in 1...total { try await channel.send(ConformanceFixture.payload("p", index)) }
        }
        let first = try await fixture.read(remote, count: 40, "before the path change")
        guard await harness.changePath(to: target) else {
            sender.cancel()
            sawTarget.cancel()
            return .skipped("harness cannot change paths")
        }
        let second = try await fixture.read(remote, count: 40, "after the path change")
        guard try await fixture.deadline.run("badge shows \(target)", { await sawTarget.value }) else {
            throw fixture.fail("badge never showed \(target)")
        }
        guard await fixture.dialer.state.path?.kind == target else { throw fixture.fail("state path not \(target)") }

        var roamed = false
        let roamTarget: PathKind = target == .p2p ? .turn : .p2p
        if await harness.roam(to: roamTarget) {
            roamed = true
        }
        let third = try await fixture.read(remote, count: Int(total) - 80, "after roam")
        try await sender.value
        try fixture.expectInOrder(first + second + third, from: 1, prefix: "p")
        if roamed {
            try await fixture.waitFor(fixture.dialer, "dialer on \(roamTarget) after roam") {
                $0.path?.kind == roamTarget
            }
        }
        return .passed
    }

    @Sendable
    func priority(_ fixture: ConformanceFixture) async throws -> ConformanceOutcome {
        let bulkSize = 32 * 1024
        let bulkCount = 16
        let (bulk, bulkRemote) = try await fixture.openPair(Self.reliable("priority/bulk", .bulk))
        let (input, inputRemote) = try await fixture.openPair(Self.reliable("priority/input", .input))
        // Both channels declared and flowing before the burst.
        try await bulk.send(Data("warm".utf8))
        try await input.send(Data("warm".utf8))
        _ = try await fixture.read(bulkRemote, count: 1, "bulk warm-up")
        _ = try await fixture.read(inputRemote, count: 1, "input warm-up")

        guard await harness.throttle(bytesPerSecond: 2 * 1024 * 1024) else {
            return .skipped("harness cannot throttle")
        }
        let order = AsyncQueue<String>()
        let bulkReader = Task {
            var iterator = bulkRemote.events.makeAsyncIterator()
            for _ in 0..<bulkCount {
                guard case .message = await iterator.next() else { return }
                await order.push("bulk")
            }
        }
        let inputReader = Task {
            var iterator = inputRemote.events.makeAsyncIterator()
            if case .message = await iterator.next() { await order.push("input") }
        }
        for index in 1...bulkCount {
            try await bulk.send(Self.chunk(UInt64(index), size: bulkSize))
        }
        try await input.send(Data("keystroke".utf8))
        try await fixture.deadline.run("all frames arrive") {
            await inputReader.value
            await bulkReader.value
        }
        _ = await harness.throttle(bytesPerSecond: nil)
        var arrivals: [String] = []
        while await order.count > 0, let next = await order.next() { arrivals.append(next) }
        guard let inputPosition = arrivals.firstIndex(of: "input") else { throw fixture.fail("input never arrived") }
        // At most the bulk frames already on the wire may precede it.
        guard inputPosition <= 3 else {
            throw fixture.fail("input arrived after \(inputPosition) of \(bulkCount) bulk frames")
        }
        return .passed
    }
}
