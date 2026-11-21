import CmuxNextCloud
import Testing

/// `cloud start-session --name` skips the idle check of a machine's agent daemon only for a machine its own
/// creation made (nothing of anyone's runs there yet): a caller that joined a creation going on, or a creation
/// that found a machine made elsewhere, is never told it made one.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CloudStartRunsMadeTests {
    @Test func onlyTheCallerThatStartedTheCreationMadeTheMachine() async throws {
        let runs = CloudStartRuns<String, String>()
        let (joins, joined) = AsyncStream<String>.makeStream()
        runs.joinedCreation = { joined.yield($0) }
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (entries, entered) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await runs.creatingOwn("dev", account: ["user-1", "team-1"]) {
                entered.yield()
                for await _ in gate { break }
                return ("vm-1", true)
            }
        }
        // The first creation is going on: the second joins it.
        for await _ in entries { break }
        let second = Task {
            try await runs.creatingOwn("dev", account: ["user-1", "team-1"]) { ("vm-2", true) }
        }
        for await name in joins { #expect(name == "dev"); break }
        open.yield()
        let made = try await first.value, join = try await second.value
        #expect(made.machine == "vm-1" && made.made)
        #expect(join.machine == "vm-1" && !join.made, "a caller that joined the creation was told it made the machine")
        open.finish(); joined.finish(); entered.finish()
    }

    @Test func aCreationThatFoundOneMadeElsewhereDidNotMakeIt() async throws {
        let runs = CloudStartRuns<String, String>()
        let found = try await runs.creatingOwn("dev", account: ["user-1", "team-1"]) { ("vm-elsewhere", false) }
        #expect(found.machine == "vm-elsewhere" && !found.made)
        // The plain form still answers the machine.
        let plain = try await runs.creating("api", account: ["user-1", "team-1"]) { "vm-3" }
        #expect(plain == "vm-3")
    }
}
