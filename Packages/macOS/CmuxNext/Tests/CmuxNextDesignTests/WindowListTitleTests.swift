import AppKit
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

    @Test @MainActor func appKitWindowsCarryThoseDistinctTitles() {
        _ = NSApplication.shared
        let personal = NSWindow()
        personal.title = WindowListTitle(spaceName: "Personal", workspaceName: "leo-workspace", incognito: false,
                                         fallbackName: "cmux", incognitoName: "Incognito").value
        let work = NSWindow()
        work.title = WindowListTitle(spaceName: "Work", workspaceName: "leo-workspace", incognito: false,
                                     fallbackName: "cmux", incognitoName: "Incognito").value

        #expect(personal.title == "Personal — leo-workspace")
        #expect(work.title == "Work — leo-workspace")
        #expect(personal.title != work.title)
    }

    @Test func incognitoTitlesIdentifyTheWindowKind() {
        #expect(WindowListTitle(spaceName: "Private", workspaceName: "research", incognito: true,
                                fallbackName: "cmux", incognitoName: "Incognito").value == "Incognito — research")
    }
}
