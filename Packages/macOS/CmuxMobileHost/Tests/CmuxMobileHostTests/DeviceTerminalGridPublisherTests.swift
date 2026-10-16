import Foundation
import Testing
@testable import CmuxMobileHost

@Suite("Device terminal grid publisher")
struct DeviceTerminalGridPublisherTests {
    @Test("Publishes only changed grids and resets on a new subscriber")
    func changedGridsAndReset() {
        let first = UUID(); let second = UUID()
        var publisher = DeviceTerminalGridPublisher()
        var values = [first: DeviceTerminalGridPublisher.Grid(columns: 80, rows: 24, generation: 1),
                       second: DeviceTerminalGridPublisher.Grid(columns: 120, rows: 40, generation: 1)]
        var emitted: [UUID] = []
        func refresh(_ topology: UInt64 = 1) {
            publisher.refresh(updatedSurfaceIDs: [first], global: true, topologyGeneration: topology,
                allSurfaceIDs: { Set(values.keys) }, sample: { values[$0] }, publish: { id, _ in emitted.append(id) })
        }
        refresh(); #expect(Set(emitted) == [first, second]); emitted.removeAll()
        refresh(); #expect(emitted.isEmpty)
        values[first] = .init(columns: 100, rows: 24, generation: 1); refresh(); #expect(emitted == [first])
        publisher.reset(); emitted.removeAll(); refresh(); #expect(Set(emitted) == [first, second])
    }

    @Test("Rejects invalid dimensions")
    func invalidDimensions() {
        var publisher = DeviceTerminalGridPublisher()
        var emitted = 0
        publisher.refresh(updatedSurfaceIDs: [], global: true, topologyGeneration: 1,
            allSurfaceIDs: { [UUID()] }, sample: { _ in .init(columns: 0, rows: 24, generation: 1) },
            publish: { _, _ in emitted += 1 })
        #expect(emitted == 0)
    }
}
