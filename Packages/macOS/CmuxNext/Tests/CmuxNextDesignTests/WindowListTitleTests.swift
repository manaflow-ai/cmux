import CmuxNextDesign
import Testing

@Suite
struct WindowListTitleTests {
    @Test func windowsOnDifferentSpacesHaveDistinctTitles() {
        let personal = WindowListTitle(spaceName: "Personal", workspaceName: "leo-workspace", incognito: false,
                                       fallbackName: "cmux", incognitoName: "Incognito").value
        let work = WindowListTitle(spaceName: "Work", workspaceName: "leo-workspace", incognito: false,
                                   fallbackName: "cmux", incognitoName: "Incognito").value

        #expect(personal == "Personal — leo-workspace")
        #expect(work == "Work — leo-workspace")
        #expect(personal != work)
    }

    @Test func connectingWindowsStillIdentifyTheirSpace() {
        #expect(WindowListTitle(spaceName: "Personal", workspaceName: nil, incognito: false,
                                fallbackName: "cmux", incognitoName: "Incognito").value == "Personal")
        #expect(WindowListTitle(spaceName: nil, workspaceName: "research", incognito: false,
                                fallbackName: "cmux", incognitoName: "Incognito").value == "cmux — research")
    }

    @Test func incognitoTitlesIdentifyTheWindowKind() {
        #expect(WindowListTitle(spaceName: "Private", workspaceName: "research", incognito: true,
                                fallbackName: "cmux", incognitoName: "Incognito").value == "Incognito — research")
    }
}
