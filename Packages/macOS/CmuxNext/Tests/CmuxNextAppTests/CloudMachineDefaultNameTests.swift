import CmuxNextCloud
import Testing

/// A new cmux-next Cloud machine with no typed name gets a readable one, never its raw id.
@Suite struct CloudMachineDefaultNameTests {
    private func pick(_ taken: [String]) -> String {
        CloudMachine.defaultName(taken: taken, base: "Cloud Machine", numbered: { "Cloud Machine \($0)" })
    }

    @Test func aChiefsComputerNameIsNumberedInsideThePossessive() {
        let name = { (taken: [String]) in
            CloudMachine.defaultName(taken: taken, base: "Chief’s Computer", numbered: { "Chief \($0)’s Computer" })
        }
        #expect(name([]) == "Chief’s Computer")
        #expect(name(["Chief’s Computer"]) == "Chief 2’s Computer")
        #expect(name(["Chief’s Computer", "Chief 2’s Computer"]) == "Chief 3’s Computer")
    }

    @Test func onlyAGeneratedNameIsADefaultName() {
        let isDefault = { (title: String) in
            CloudMachine.isDefaultName(title, base: "Cloud Machine", numbered: { "Cloud Machine \($0)" })
        }
        #expect(isDefault("Cloud Machine"))
        #expect(isDefault("Cloud Machine 5"))
        for typed in ["Cloud Machine 5 old", "My Cloud Machine", "cloud-chats", "lab2", ""] { #expect(!isDefault(typed), "\(typed)") }
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
