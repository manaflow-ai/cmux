import Foundation
import Testing
@testable import CmuxMobileSupport

@Suite struct MobileAttachmentFileNameTests {
    @Test func plainNamesPassThrough() {
        #expect(MobileAttachmentFileName.sanitized("report.pdf") == "report.pdf")
        #expect(MobileAttachmentFileName.sanitized("Screen Shot 1.png") == "Screen Shot 1.png")
        #expect(MobileAttachmentFileName.sanitized("..hidden.txt") == "..hidden.txt")
    }

    /// A pasteboard provider controls `suggestedName`; path components in it
    /// must never steer the copy outside the attachment's wrapper directory.
    @Test func pathComponentsReduceToTheFinalName() {
        #expect(MobileAttachmentFileName.sanitized("../../Library/Application Support/ssh/ssh-known-hosts.json") == "ssh-known-hosts.json")
        #expect(MobileAttachmentFileName.sanitized("/etc/passwd") == "passwd")
        #expect(MobileAttachmentFileName.sanitized("folder/report.pdf/") == "report.pdf")
    }

    @Test func namesThatAreNotAFileAreRejected() {
        #expect(MobileAttachmentFileName.sanitized("") == nil)
        #expect(MobileAttachmentFileName.sanitized(".") == nil)
        #expect(MobileAttachmentFileName.sanitized("..") == nil)
        #expect(MobileAttachmentFileName.sanitized("a/..") == nil)
        #expect(MobileAttachmentFileName.sanitized("///") == nil)
        #expect(MobileAttachmentFileName.sanitized("bad\u{0}name.png") == nil)
        #expect(MobileAttachmentFileName.sanitized(String(repeating: "a", count: 256)) == nil)
    }

    @Test func sanitizedNamesStayInsideTheirDirectory() {
        let wrapper = URL(fileURLWithPath: "/tmp/cmux-pasted-attachment-X", isDirectory: true)
        for raw in ["../../escape.json", "a/../../b", "./x", "..", "ok.png", "/abs/path.txt"] {
            guard let name = MobileAttachmentFileName.sanitized(raw) else { continue }
            let destination = wrapper.appendingPathComponent(name).standardizedFileURL
            #expect(destination.deletingLastPathComponent().path == wrapper.standardizedFileURL.path, "\(raw)")
        }
    }
}
