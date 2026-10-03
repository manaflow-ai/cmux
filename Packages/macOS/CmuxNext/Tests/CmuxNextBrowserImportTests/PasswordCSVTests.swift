import Foundation
import Testing
@testable import CmuxNextBrowserImport

/// Synthetic CSV exports only: every password is a made-up marker.
@Suite struct PasswordCSVTests {
    static let marker = "cmux-test-secret-\(UUID().uuidString)"

    func read(_ csv: String) throws -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        let bytes = Array(csv.utf8)
        return try bytes.withUnsafeBytes { try PasswordCSVReader().read($0) }
    }

    func plain(_ secret: SecretBytes) -> String { secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } }

    /// Chrome and Edge: name,url,username,password,note, CRLF, quoted fields
    /// with commas, quotes and newlines.
    @Test func readsAChromeExport() throws {
        let csv = "name,url,username,password,note\r\n"
            + "github.com,https://github.com/login,octo,\(Self.marker)-a,\r\n"
            + "news,https://NEWS.example:443/signin,\"last, first\",\"\(Self.marker)-\"\"quoted\"\", with, commas\",\"line one\nline two\"\r\n"
            + "lab,http://lab.example:8080/,admin,\(Self.marker)-c,\r\n"
        let (logins, skipped) = try read(csv)
        #expect(logins.map(\.signonRealm) == ["https://github.com/", "https://news.example/", "http://lab.example:8080/"])
        #expect(logins.map(\.username) == ["octo", "last, first", "admin"])
        #expect(logins.map { plain($0.password) } == ["\(Self.marker)-a", "\(Self.marker)-\"quoted\", with, commas", "\(Self.marker)-c"])
        #expect(skipped == LoginSkipCounts())
    }

    /// Safari, Firefox and Bitwarden name their columns differently; a byte order mark is skipped.
    @Test func readsOtherExportsByTheirHeaders() throws {
        let safari = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\nSite,https://a.example/,u,\(Self.marker),,\n"
        #expect(try read(safari).logins.map(\.signonRealm) == ["https://a.example/"])
        let firefox = "\"url\",\"username\",\"password\",\"httpRealm\"\n\"https://b.example\",\"u\",\"\(Self.marker)\",\"\"\n"
        #expect(try read(firefox).logins.map(\.signonRealm) == ["https://b.example/"])
        let bitwarden = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
            + ",,login,c,,,0,https://c.example/x,u,\(Self.marker),\n"
        #expect(try read(bitwarden).logins.map(\.username) == ["u"])
    }

    /// Username before email, per row: Proton Pass has both columns, email
    /// first, and two accounts on one site stay two.
    @Test func prefersTheUsernameColumnAndFallsBackPerRow() throws {
        let csv = "type,name,url,email,username,password\n"
            + "login,a,https://a.example/,me@mail.example,octo,\(Self.marker)-1\n"
            + "login,b,https://a.example/,,second,\(Self.marker)-2\n"
            + "login,c,https://a.example/,third@mail.example,,\(Self.marker)-3\n"
            + "login,d,https://a.example/,fourth@mail.example, ,\(Self.marker)-4\n"
        let (logins, skipped) = try read(csv)
        #expect(logins.map(\.username) == ["octo", "second", "third@mail.example", "fourth@mail.example"])
        #expect(skipped == LoginSkipCounts())
    }

    /// The stored page URL drops user, password, query and fragment; the
    /// realm keys the host as Chromium does (punycode, IPv6 in brackets).
    @Test func keysTheSiteAsChromiumDoes() {
        let form = PasswordCSVReader.webForm("https://me:\(Self.marker)@a.example/login?next=1#top")
        #expect(form?.url == "https://a.example/login")
        #expect(form?.realm == "https://a.example/")
        #expect(PasswordCSVReader.webForm("https://bücher.example/")?.realm == "https://xn--bcher-kva.example/")
        #expect(PasswordCSVReader.webForm("https://[::1]:8443/x")?.realm == "https://[::1]:8443/")
    }

    /// Firefox's HTTP authentication rows (an `httpRealm`) are not web forms.
    @Test func skipsHTTPAuthenticationRows() throws {
        let csv = "url,username,password,httpRealm\n"
            + "https://a.example,u,\(Self.marker),\n"
            + "https://b.example,u,\(Self.marker),Staff only\n"
        let (logins, skipped) = try read(csv)
        #expect(logins.map(\.signonRealm) == ["https://a.example/"])
        #expect(skipped.notWebForm == 1)
    }

    /// Rows cmux cannot use are counted, never stored: no password, not a
    /// web page, not text, or the same site and username again.
    @Test func countsWhatItSkips() throws {
        let csv = "url,username,password\n"
            + "https://a.example/,u,\(Self.marker)\n"
            + "https://a.example/other,u,\(Self.marker)-again\n"
            + "https://b.example/,u,\n"
            + "android://app,u,\(Self.marker)\n"
            + "not a url,u,\(Self.marker)\n"
            + "\n"
        var bytes = Array(csv.utf8)
        // A password that is not UTF-8.
        bytes += Array("https://c.example/,u,".utf8) + [0xFF, 0xFE] + Array("\n".utf8)
        let (logins, skipped) = try bytes.withUnsafeBytes { try PasswordCSVReader().read($0) }
        #expect(logins.map(\.signonRealm) == ["https://a.example/"])
        var expected = LoginSkipCounts()
        expected.duplicate = 1
        expected.empty = 1
        expected.notWebForm = 2
        expected.undecryptable = 1
        #expect(skipped == expected)
    }

    @Test func refusesAFileWithoutPasswordColumns() {
        #expect(throws: PasswordCSVReader.Failure.noPasswordColumns) { try read("name,url,username\nx,https://a.example/,u\n") }
        #expect(throws: PasswordCSVReader.Failure.noPasswordColumns) { try read("") }
    }

    /// The import stores what it read into the chosen profile and reports counts only.
    @Test func importsIntoTheStoreAndReportsCountsOnly() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "passwords-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("url,username,password\nhttps://a.example/,u,\(Self.marker)\nhttps://b.example/,v,\(Self.marker)\n,w,\n".utf8).write(to: url)
        let store = RecordingPasswordStore(reply: PasswordStoreReply(added: 1, duplicate: 1))
        let report = try await PasswordCSVImporter(destination: store).run(file: url, intoProfile: "work")
        #expect(store.batches == [["https://a.example/", "https://b.example/"]])
        #expect(store.profiles == ["work"])
        #expect(report.read == 3 && report.imported == 1 && report.notImported == 2)
        #expect(!String(describing: report).contains(Self.marker))
    }

    /// The file goes straight into a locked buffer, and only a regular file of a sane size is read.
    @Test func readsTheFileIntoSecretBytes() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "passwords-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("url,password\nhttps://a.example/,\(Self.marker)\n".utf8).write(to: url)
        let bytes = try PasswordCSVImporter.read(url)
        #expect(bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == "url,password\nhttps://a.example/,\(Self.marker)\n")
        #expect(throws: PasswordCSVImporter.Failure.unreadable) { try PasswordCSVImporter.read(FileManager.default.temporaryDirectory) }
        #expect(throws: PasswordCSVImporter.Failure.noPasswordColumns) { try PasswordCSVImporter.parse(SecretBytes(copying: Array("a,b\n".utf8))) }
    }

    /// The file on disk is left as it was (the user decides about it), and
    /// nothing runs without a store.
    @Test func readsTheFileWithoutChangingIt() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "passwords-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "url,username,password\nhttps://a.example/,u,\(Self.marker)\n"
        try Data(text.utf8).write(to: url)
        _ = try await PasswordCSVImporter(destination: RecordingPasswordStore()).run(file: url, intoProfile: "default")
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        await #expect(throws: PasswordCSVImporter.Failure.storeUnavailable) {
            try await PasswordCSVImporter(destination: RecordingPasswordStore(available: false)).run(file: url, intoProfile: "default")
        }
        await #expect(throws: PasswordCSVImporter.Failure.unreadable) {
            try await PasswordCSVImporter(destination: RecordingPasswordStore()).run(file: url.appending(path: "missing"), intoProfile: "default")
        }
    }
}
