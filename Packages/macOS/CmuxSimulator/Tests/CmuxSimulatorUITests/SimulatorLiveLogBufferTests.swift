import Testing

@testable import CmuxSimulatorUI

@Suite("Simulator live log buffer")
struct SimulatorLiveLogBufferTests {
    @Test("Storage stays byte-bounded for non-ASCII log batches")
    func byteBound() async {
        let buffer = SimulatorLiveLogBuffer()
        let first = await buffer.append("ready\n")
        #expect(first == "ready\n")

        _ = await buffer.append(String(repeating: "🙂", count: 60_000))

        #expect(await buffer.storedByteCount <= 150_000)
        #expect(!(await buffer.snapshot()).isEmpty)
    }
}
