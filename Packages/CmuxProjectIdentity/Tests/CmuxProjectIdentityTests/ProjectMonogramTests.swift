import Testing
@testable import CmuxProjectIdentity

@Test func monogramSingleWordTakesTwoLetters() {
    #expect(ProjectMonogram(projectName: "cmux").value == "CM")
    #expect(ProjectMonogram(projectName: "webapp").value == "WE")
}
@Test func monogramMultiWordTakesInitials() {
    #expect(ProjectMonogram(projectName: "activelens-api").value == "AA")
    #expect(ProjectMonogram(projectName: "my_cool.app").value == "MC")
}
@Test func monogramHandlesShortAndEmpty() {
    #expect(ProjectMonogram(projectName: "x").value == "X")
    #expect(ProjectMonogram(projectName: "").value == "?")
    #expect(ProjectMonogram(projectName: "  - _ ").value == "?")
}
