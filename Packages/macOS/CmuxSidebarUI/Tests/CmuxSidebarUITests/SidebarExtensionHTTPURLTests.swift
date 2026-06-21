import Foundation
import Testing

@testable import CmuxSidebarUI

@Suite("SidebarExtensionHTTPURL")
struct SidebarExtensionHTTPURLTests {
    @Test("required accepts http and https with a host")
    func requiredAcceptsValid() {
        #expect(URL.sidebarExtensionHTTPURL(from: "http://example.com") != nil)
        #expect(URL.sidebarExtensionHTTPURL(from: "https://example.com/path?q=1") != nil)
        // Scheme case is normalized before comparison.
        #expect(URL.sidebarExtensionHTTPURL(from: "HTTPS://example.com") != nil)
    }

    @Test("required rejects non-http schemes, schemeless, and hostless URLs")
    func requiredRejectsInvalid() {
        #expect(URL.sidebarExtensionHTTPURL(from: "ftp://example.com") == nil)
        #expect(URL.sidebarExtensionHTTPURL(from: "file:///etc/hosts") == nil)
        #expect(URL.sidebarExtensionHTTPURL(from: "example.com") == nil)
        #expect(URL.sidebarExtensionHTTPURL(from: "http://") == nil)
        #expect(URL.sidebarExtensionHTTPURL(from: "") == nil)
    }

    @Test("optional accepts empty and nil as accepted with no url")
    func optionalAcceptsEmpty() {
        let fromNil = SidebarExtensionOptionalHTTPURL(validating: nil)
        #expect(fromNil.accepted)
        #expect(fromNil.url == nil)

        let fromEmpty = SidebarExtensionOptionalHTTPURL(validating: "")
        #expect(fromEmpty.accepted)
        #expect(fromEmpty.url == nil)
    }

    @Test("optional accepts a valid url and carries it")
    func optionalAcceptsValid() {
        let result = SidebarExtensionOptionalHTTPURL(validating: "https://example.com")
        #expect(result.accepted)
        #expect(result.url == URL(string: "https://example.com"))
    }

    @Test("optional rejects an invalid non-empty url")
    func optionalRejectsInvalid() {
        let result = SidebarExtensionOptionalHTTPURL(validating: "not a url")
        #expect(!result.accepted)
        #expect(result.url == nil)
    }
}
