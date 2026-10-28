@testable import CmuxNextApps
import Foundation
import Testing

/// A local app packed for the App Store's review queue (custom-panes-DESIGN.md section 6.4):
/// `local/<name>` becomes `<publisher>/<name>` in the manifest and its file, hidden files,
/// symlinks and `node_modules` stay home, and a publisher the repository does not belong to, a
/// reserved one or another app's folder is refused before anything is sent.
struct AppRegistrySubmissionTests {
    @Test func aLocalAppIsPackedUnderThePublisher() throws {
        let app = try LocalApp(repository: "https://github.com/Octo/board")
        let packed = try AppRegistrySubmission(bundle: app.root, localID: "local/board", publisher: "octo")
        #expect(packed.app == "octo/board")
        #expect(packed.version == "1.0.0")
        #expect(Set(packed.files.keys) == ["cmux-app.json", "web/index.html", "web/app.js"], "\(packed.files.keys.sorted())")
        let manifestFile = try #require(packed.files["cmux-app.json"].flatMap { Data(base64Encoded: $0) })
        #expect(try AppJSON.parse(manifestFile) == packed.manifest, "the file is the manifest that is sent")
        #expect(packed.files["web/app.js"].flatMap { Data(base64Encoded: $0) } == Data("cmux.call('workspace.list')".utf8))
    }

    @Test func aPublisherTheRepositoryDoesNotBelongToIsRefused() throws {
        let app = try LocalApp(repository: "https://github.com/someone-else/board")
        let refusal = #expect(throws: AppRegistrySubmission.Failure.self) {
            try AppRegistrySubmission(bundle: app.root, localID: "local/board", publisher: "octo")
        }
        #expect(refusal?.message.contains("https://github.com/octo/") == true)
        let unset = try LocalApp(repository: nil)
        #expect(throws: AppRegistrySubmission.Failure.self) {
            try AppRegistrySubmission(bundle: unset.root, localID: "local/board", publisher: "octo")
        }
    }

    @Test func reservedPublishersAndOtherAppsAreRefused() throws {
        let app = try LocalApp(repository: "https://github.com/cmux/board")
        for publisher in ["cmux", "local", "Octo", "-x", "", String(repeating: "a", count: 40)] {
            #expect(throws: AppRegistrySubmission.Failure.self, "\(publisher)") {
                try AppRegistrySubmission(bundle: app.root, localID: "local/board", publisher: publisher)
            }
        }
        #expect(throws: AppRegistrySubmission.Failure.self, "the folder holds local/board") {
            try AppRegistrySubmission(bundle: app.root, localID: "local/other", publisher: "octo")
        }
        #expect(throws: AppRegistrySubmission.Failure.self, "only a local app") {
            try AppRegistrySubmission(bundle: app.root, localID: "octo/board", publisher: "octo")
        }
    }

    @Test func aPublisherMayStartWithADigit() throws {
        let app = try LocalApp(repository: "https://github.com/0x/board")
        #expect(try AppRegistrySubmission(bundle: app.root, localID: "local/board", publisher: "0x").app == "0x/board")
    }

    @Test func theRepositoryOwnerIsReadFromAGitHubURLOnly() {
        #expect(AppRegistrySubmission.repositoryOwner("https://github.com/Octo/board") == "octo")
        #expect(AppRegistrySubmission.repositoryOwner("https://github.com/octo") == nil)
        #expect(AppRegistrySubmission.repositoryOwner("https://gitlab.com/octo/board") == nil)
        #expect(AppRegistrySubmission.repositoryOwner(nil) == nil)
    }
}

/// `local/board` with a web pane, a hidden file, a symlink and a node_modules folder.
private struct LocalApp {
    let root: URL

    init(repository: String?) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        let repositoryField = repository.map { #","repository":"\#($0)""# } ?? ""
        let manifest = #"{"manifestVersion":2,"id":"local/board","name":"Board","version":"1.0.0","description":"d"\#(repositoryField)}"#
        try manifest.write(to: root.appendingPathComponent("cmux-app.json"), atomically: true, encoding: .utf8)
        try "<script src=app.js></script>".write(to: root.appendingPathComponent("web/index.html"), atomically: true, encoding: .utf8)
        try "cmux.call('workspace.list')".write(to: root.appendingPathComponent("web/app.js"), atomically: true, encoding: .utf8)
        try "SECRET=1".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("node_modules/x/index.js"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: root.appendingPathComponent("web/home"), withDestinationURL: manager.homeDirectoryForCurrentUser)
    }
}
