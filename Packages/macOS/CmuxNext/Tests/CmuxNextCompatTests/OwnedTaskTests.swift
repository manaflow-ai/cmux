import CmuxNextCompat
import Testing

struct OwnedTaskTests {
    @Test func releasingOrReplacingAnOwnerCancelsItsTask() {
        let first = Task<Void, Never> {}
        let second = Task<Void, Never> {}
        var owner: OwnedTask? = first.owned()
        #expect(owner != nil)
        #expect(!first.isCancelled)
        owner = second.owned()
        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        #expect(owner != nil)
        owner = nil
        #expect(second.isCancelled)
    }
}
