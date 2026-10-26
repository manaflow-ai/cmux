@testable import CmuxFuzzSupport
import Foundation
import Testing

@Suite struct FuzzRNGTests {
    @Test func aSeedGivesTheSameChoicesAndZeroIsUsable() {
        var a = FuzzRNG(seed: 0xC0_17)
        var b = FuzzRNG(seed: 0xC0_17)
        let first = (0..<64).map { _ in a.next() }
        let second = (0..<64).map { _ in b.next() }
        #expect(first == second)
        var zero = FuzzRNG(seed: 0)
        let fromZero = (0..<8).map { _ in zero.next() }
        #expect(fromZero.contains { $0 != 0 })
    }

    /// The suites' old private generator: xorshift64 (13, 7, 17), `next() % n` for `below`.
    @Test func seededDrawsMatchTheSuitesPreviousGenerator() {
        var state: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        func reference() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_CAFE_F00D)
        for n in [1, 3, 24, 1_000, Int.max] {
            let drawn = rng.below(n)
            let expected = Int(reference() % UInt64(n))
            #expect(drawn == expected)
        }
        let byte = rng.byte()
        #expect(byte == UInt8(truncatingIfNeeded: reference()))
    }

    @Test func derivedSeedsDifferPerStream() {
        let seeds = Set((0..<1_000).map { FuzzRNG.derivedSeed(7, stream: UInt64($0)) })
        #expect(seeds.count == 1_000)
        #expect(FuzzRNG.derivedSeed(7, stream: 3) == FuzzRNG.derivedSeed(7, stream: 3))
    }

    @Test func boundedDrawsStayInRange() {
        var rng = FuzzRNG(seed: 99)
        for _ in 0..<5_000 {
            let below = rng.below(7)
            let none = rng.below(0)
            let negative = rng.below(-4)
            let int = rng.int(in: -3...5)
            let double = rng.double(in: 0.5...2.0)
            let bytes = rng.bytes(16)
            let text = rng.text(["a", "b"], 5)
            #expect((0..<7).contains(below))
            #expect(none == 0 && negative == 0)
            #expect((-3...5).contains(int))
            #expect((0.5...2.0).contains(double))
            #expect(bytes.count < 16)
            #expect(text.count < 5)
        }
        _ = rng.int(in: Int.min...Int.max)
        let single = rng.int(in: 4...4)
        #expect(single == 4)
        let none = rng.element(of: [Int]())
        #expect(none == nil)
    }

    @Test func replayReadsTheInputLittleEndianAndOnlyTheBytesARangeNeeds() {
        var rng = FuzzRNG(replaying: Data([5, 0x34, 0x12, 1, 2, 3, 4, 5, 6, 7, 8]))
        let small = rng.below(10)
        let wide = rng.below(0x10000)
        #expect(small == 5)
        #expect(wide == 0x1234)
        #expect(!rng.isExhausted)
        let whole = rng.next()
        #expect(whole == 0x0807_0605_0403_0201)
        #expect(rng.isExhausted)
    }

    /// Bounded draws give their low end once the input is used up, so loops sized by a draw end;
    /// `next()` goes on with a stream, so the standard library's rejection sampling finishes.
    @Test func anExhaustedReplayEndsLoopsAndNeverStallsTheStandardLibrary() {
        var rng = FuzzRNG(replaying: Data())
        #expect(rng.isExhausted)
        let below = rng.below(100)
        let byte = rng.byte()
        let bytes = rng.bytes(64)
        let int = rng.int(in: 3...9)
        let double = rng.double(in: 1...2)
        #expect(below == 0 && byte == 0 && bytes.isEmpty)
        #expect(int == 3)
        #expect(double == 1)
        let stream = (0..<4).map { _ in rng.next() }
        #expect(stream.contains { $0 != 0 })
        for _ in 0..<1_000 {
            let value = Int.random(in: 0...12, using: &rng)
            #expect((0...12).contains(value))
        }
        let element = [1, 2, 3].randomElement(using: &rng)
        #expect(element != nil)
    }
}

@Suite struct FuzzMutatorTests {
    @Test func everyEditKeepsTheInputWithinItsBound() {
        let mutator = FuzzMutator(dictionary: [Data("method".utf8), Data()], maximumCount: 64)
        #expect(mutator.dictionary == [Array("method".utf8)])
        var rng = FuzzRNG(seed: 4)
        var input = Data("{\"method\":\"x\"}".utf8)
        for _ in 0..<5_000 {
            input = mutator.mutate(input, crossingWith: Data([1, 2, 3]), using: &rng)
            #expect(input.count <= 64)
        }
    }

    @Test func anEditThatCannotApplyInsertsAByte() {
        var rng = FuzzRNG(seed: 5)
        for edit in FuzzMutator.Edit.allCases where edit != .duplicatePrefix {
            var bytes: [UInt8] = []
            FuzzMutator().apply(edit, to: &bytes, using: &rng)
            #expect(bytes.count == 1, "\(edit)")
        }
    }

    @Test func tokensAndCrossOverUseTheirSources() {
        var rng = FuzzRNG(seed: 6)
        var bytes: [UInt8] = [0, 0, 0, 0]
        FuzzMutator(dictionary: [Data([9, 9])]).apply(.insertToken, to: &bytes, using: &rng)
        #expect(bytes.count == 6 && bytes.filter { $0 == 9 }.count == 2)
        var crossed: [UInt8] = [1, 1]
        FuzzMutator().apply(.crossOver, to: &crossed, partner: [7, 7, 7], using: &rng)
        #expect(crossed.contains(7) && crossed.allSatisfy { $0 == 1 || $0 == 7 })
    }

    @Test func aSeedGivesTheSameMutation() {
        var a = FuzzRNG(seed: 11)
        var b = FuzzRNG(seed: 11)
        let input = Data("cmux".utf8)
        let first = FuzzMutator().mutate(input, using: &a)
        let second = FuzzMutator().mutate(input, using: &b)
        #expect(first == second)
    }
}

@Suite struct FuzzEnvironmentTests {
    @Test func variablesParse() throws {
        let environment = try FuzzEnvironment(variables: [
            "CMUX_FUZZ_SECONDS": "300", "CMUX_FUZZ_SEED": "0xFF", "CMUX_FUZZ_ARTIFACTS": "/tmp/a", "CMUX_FUZZ_CORPUS": " ",
        ])
        #expect(environment.seconds == 300 && environment.isLongMode)
        #expect(environment.seed == 255)
        #expect(environment.artifacts?.path == "/tmp/a")
        #expect(environment.corpus == nil)
        let plain = try FuzzEnvironment(variables: ["CMUX_FUZZ_SEED": "42", "CMUX_FUZZ_SECONDS": "0"])
        #expect(plain == FuzzEnvironment(seed: 42))
        #expect(!plain.isLongMode)
    }

    @Test(arguments: zip(
        ["CMUX_FUZZ_SECONDS", "CMUX_FUZZ_SECONDS", "CMUX_FUZZ_SECONDS", "CMUX_FUZZ_SEED", "CMUX_FUZZ_SEED"],
        ["soon", "-1", "inf", "0xZZ", "-3"]
    ))
    func aValueThatDoesNotParseIsAnError(_ name: String, _ value: String) {
        #expect(throws: FuzzError.badVariable(name: name, value: value)) {
            try FuzzEnvironment(variables: [name: value])
        }
    }
}

@Suite struct FuzzRunTests {
    @Test func defaultModeRunsExactlyTheIterationsAndASeedVariableReplacesTheSeed() throws {
        var count = 0
        let run = FuzzRun("count", seed: 1, iterations: 37, environment: FuzzEnvironment())
        let ran = try run.forEach { _ in count += 1 }
        #expect(ran == 37 && count == 37)
        #expect(FuzzRun("seed", seed: 1, iterations: 1, environment: FuzzEnvironment(seed: 9)).seed == 9)
    }

    @Test func iterationsDrawFromTheirOwnReplayableGenerators() throws {
        let run = FuzzRun("streams", seed: 3, iterations: 5, environment: FuzzEnvironment())
        var draws: [UInt64] = []
        try run.forEach { rng in draws.append(rng.next()) }
        #expect(draws.count == 5 && Set(draws).count == 5)
        var third = run.generator(for: 2)
        let replayed = third.next()
        #expect(replayed == draws[2])
    }

    @Test func longModeGoesPastTheIterations() throws {
        let run = FuzzRun("long", seed: 1, iterations: 3, environment: FuzzEnvironment(seconds: 0.05))
        let started = ContinuousClock.now
        let ran = try run.forEach { _ in }
        let elapsed = ContinuousClock.now - started
        #expect(ran > 3)
        #expect(elapsed >= .milliseconds(50))
    }

    @Test func aFailureNamesItsSeedAndIteration() throws {
        let run = FuzzRun("fails", seed: 0xAB, iterations: 10, environment: FuzzEnvironment())
        var seen = 0
        do {
            try run.forEach { _ in
                seen += 1
                try FuzzRun.check(seen < 4, "the fourth fails")
            }
            Issue.record("the run did not fail")
        } catch FuzzError.failed(let failure) {
            #expect(failure.name == "fails" && failure.seed == 0xAB && failure.iteration == 3)
            #expect(failure.reason.contains("the fourth fails"))
            #expect(failure.replay.hasPrefix("CMUX_FUZZ_SEED=0xab"))
        }
    }

    @Test func inputRunsStartWithTheCorpusAsItIs() throws {
        let run = FuzzRun("inputs", seed: 2, iterations: 20, environment: FuzzEnvironment())
        var inputs: [Data] = []
        let corpus = try run.corpus(seeds: [Data("a".utf8), Data("bc".utf8)])
        let ran = try run.forEachInput(corpus) { inputs.append($0) }
        #expect(ran == 22 && inputs.count == 22)
        #expect(Array(inputs.prefix(2)) == [Data("a".utf8), Data("bc".utf8)])
        var empty = 0
        try run.forEachInput(FuzzCorpus(seeds: [])) { _ in empty += 1 }
        #expect(empty == 20)
    }

    @Test func storedCorpusFilesFollowTheSeedsInNameOrder() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Suite.case", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("2".utf8).write(to: folder.appendingPathComponent("b"))
        try Data("1".utf8).write(to: folder.appendingPathComponent("a"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".skip"))
        let run = FuzzRun("Suite.case", seed: 1, iterations: 0, environment: FuzzEnvironment(corpus: root))
        let inputs = try run.corpus(seeds: [Data("0".utf8)]).inputs
        #expect(inputs == ["0", "1", "2"].map { Data($0.utf8) })
        let missing = FuzzRun("none", seed: 1, iterations: 0, environment: FuzzEnvironment(corpus: root))
        let nothing = try missing.corpus(seeds: [])
        #expect(nothing.isEmpty)
    }

    @Test func aThrownFailureIsKeptAndTheInflightFilesAreRemoved() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = FuzzRun("Kept/Run", seed: 0x10, iterations: 50, environment: FuzzEnvironment(artifacts: root))
        do {
            try run.forEachInput(FuzzCorpus(seeds: [Data("ok".utf8), Data("bad".utf8)])) { input in
                try FuzzRun.check(input != Data("bad".utf8), "bad input")
            }
            Issue.record("the run did not fail")
        } catch FuzzError.failed(let failure) {
            #expect(failure.iteration == -2 && failure.input == Data("bad".utf8))
            let artifact = try #require(failure.artifact)
            #expect(artifact.lastPathComponent == "Kept_Run-10--2.txt")
            let kept = try Data(contentsOf: artifact.deletingPathExtension().appendingPathExtension("input"))
            #expect(kept == Data("bad".utf8))
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["Kept_Run-10--2.input", "Kept_Run-10--2.txt"])
    }

    @Test func runNamesBecomeSafeFileNames() {
        #expect(FuzzArtifacts.fileName(for: "a/b c") == "a_b_c")
        #expect(FuzzArtifacts.fileName(for: "..") == "run")
        #expect(FuzzArtifacts.fileName(for: "") == "run")
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
