import Foundation
import Testing
@testable import CmuxMobileSupport

@Suite struct MobileAttachmentFileNameTests {
    @Test func plainNamesPassThrough() {
        #expect(MobileAttachmentFileName("report.pdf")?.value == "report.pdf")
        #expect(MobileAttachmentFileName("Screen Shot 1.png")?.value == "Screen Shot 1.png")
        #expect(MobileAttachmentFileName("..hidden.txt")?.value == "..hidden.txt")
    }

    /// A pasteboard provider controls `suggestedName`; path components in it
    /// must never steer the copy outside the attachment's wrapper directory.
    @Test func pathComponentsReduceToTheFinalName() {
        #expect(MobileAttachmentFileName("../../Library/Application Support/ssh/ssh-known-hosts.json")?.value == "ssh-known-hosts.json")
        #expect(MobileAttachmentFileName("/etc/passwd")?.value == "passwd")
        #expect(MobileAttachmentFileName("folder/report.pdf/")?.value == "report.pdf")
    }

    @Test func namesThatAreNotAFileAreRejected() {
        #expect(MobileAttachmentFileName("") == nil)
        #expect(MobileAttachmentFileName(".") == nil)
        #expect(MobileAttachmentFileName("..") == nil)
        #expect(MobileAttachmentFileName("a/..") == nil)
        #expect(MobileAttachmentFileName("///") == nil)
        #expect(MobileAttachmentFileName("bad\u{0}name.png") == nil)
        #expect(MobileAttachmentFileName(String(repeating: "a", count: 256)) == nil)
    }

    @Test func sanitizedNamesStayInsideTheirDirectory() {
        let wrapper = URL(fileURLWithPath: "/tmp/cmux-pasted-attachment-X", isDirectory: true)
        for raw in ["../../escape.json", "a/../../b", "./x", "..", "ok.png", "/abs/path.txt"] {
            guard let name = MobileAttachmentFileName(raw)?.value else { continue }
            let destination = wrapper.appendingPathComponent(name).standardizedFileURL
            #expect(destination.deletingLastPathComponent().path == wrapper.standardizedFileURL.path, "\(raw)")
        }
    }
}
