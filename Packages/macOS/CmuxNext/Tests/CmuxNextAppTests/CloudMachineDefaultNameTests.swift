import CmuxNextCloud
import Testing

/// A new cmux-next Cloud machine with no typed name gets a readable one, never its raw id.
@Suite struct CloudMachineDefaultNameTests {
    private func pick(_ taken: [String]) -> String {
        CloudMachine.defaultName(taken: taken, base: "Cloud Machine", numbered: { "Cloud Machine \($0)" })
    }

    @Test func theFirstMachineIsCloudMachine() {
        #expect(pick([]) == "Cloud Machine")
        #expect(pick(["vm_8f2c1a", "build-box"]) == "Cloud Machine")
    }

    @Test func aTakenNameCountsOnFromTwo() {
        #expect(pick(["Cloud Machine"]) == "Cloud Machine 2")
        #expect(pick(["Cloud Machine", "Cloud Machine 2"]) == "Cloud Machine 3")
        #expect(pick(["Cloud Machine", "Cloud Machine 3"]) == "Cloud Machine 2", "the first free number")
    }

    @Test func titlesCompareTrimmedAndCaseInsensitively() {
        #expect(pick([" cloud machine "]) == "Cloud Machine 2")
    }

    @Test func aMachineWithNoNameIsTitledByItsDefaultOnlyOnceNamed() {
        let unnamed = CloudMachine(id: "vm_8f2c1a", provider: "cmux-next")
        #expect(unnamed.title == "vm_8f2c1a", "an old record keeps its id; only new creates get a name")
        let named = CloudMachine(id: "vm_8f2c1a", provider: "cmux-next", displayName: pick([unnamed.title]))
        #expect(named.title == "Cloud Machine")
    }
}
