import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A file dropped into a chat moved to a Cloud machine goes there whatever its size: the app sets
/// no size limit on a staged upload, on one file or on a batch, and its failure text names none
/// (Leo, 2026-10-26: "WE NEED ARBITARRILY LARGE FILES OF ANY TYPE"). The begin is checked through
/// ``CloudUploads/beginRefusal(name:size:manifest:)``, the same check the stager runs; the sizes
/// are only declared, so no bytes are written.
@MainActor @Suite struct CloudUploadsTests {
    /// Past the former 32 MiB per-file limit, a lone file's begin is taken.
    @Test(arguments: [32 * 1024 * 1024 + 1, (1 << 30) + 1, 8 << 30])
    func aBeginOfAnySizeIsTaken(size: Int) {
        #expect(CloudUploads.beginRefusal(name: "recording.mov", size: size, manifest: nil) == nil)
    }

    /// A batch past the former 64 MiB total, and one whose files each pass the former 32 MiB, is taken.
    @Test func aBatchOfAnySizeIsTaken() {
        let thirty = 30 * 1024 * 1024
        let overTotal = (0..<3).map { AgentPaneUploadBatchEntry(name: "part-\($0).bin", size: thirty) }
        #expect(CloudUploads.beginRefusal(name: "part-0.bin", size: thirty, manifest: overTotal) == nil)
        let large = [AgentPaneUploadBatchEntry(name: "a.mov", size: 40 * 1024 * 1024),
                     AgentPaneUploadBatchEntry(name: "b.mov", size: 2 << 30)]
        #expect(CloudUploads.beginRefusal(name: "a.mov", size: 40 * 1024 * 1024, manifest: large) == nil)
    }

    /// The page's begin past the former 1 GiB decoder limit, alone or with a batch naming a file past
    /// it, decodes as the bridge decodes it (``DecodedStagedBegins``) and the Cloud stager's begin
    /// check takes it.
    @Test(arguments: [2 << 30, 8 << 30])
    func aDecodedBeginOfAnySizeReachesTheCloudStager(size: Int) throws {
        for (params, begin) in DecodedStagedBegins.cases(size: size) {
            let stage = try #require(DecodedStagedBegins.decode(params), "the decoder refused \(params)")
            #expect(stage == begin)
            guard case .begin(let name, let staged, _, let manifest) = stage else { continue }
            #expect(CloudUploads.beginRefusal(name: name, size: staged, manifest: manifest) == nil)
        }
    }

    /// A batch whose first entry is not the file begun, or that names a negative size, is still refused.
    @Test func aMalformedBatchIsStillRefused() {
        let entries = [AgentPaneUploadBatchEntry(name: "a.bin", size: 1), AgentPaneUploadBatchEntry(name: "b.bin", size: 2)]
        #expect(CloudUploads.beginRefusal(name: "b.bin", size: 2, manifest: entries) != nil)
        #expect(CloudUploads.beginRefusal(name: "a.bin", size: 2, manifest: entries) != nil)
        let negative = [AgentPaneUploadBatchEntry(name: "a.bin", size: 1), AgentPaneUploadBatchEntry(name: "b.bin", size: -1)]
        #expect(CloudUploads.beginRefusal(name: "a.bin", size: 1, manifest: negative) != nil)
    }

    /// No language's Cloud upload failure carries a placeholder or a number: there is no limit to
    /// name. Read from each `<lang>.lproj` of the app's bundle, so it does not depend on the runner's
    /// language; a key the catalog no longer has is skipped, the generic failure must be there.
    @Test func noLanguagesUploadFailureNamesALimit() throws {
        let bundle = CloudUploadStrings.bundle
        let languages = bundle.localizations.filter { $0 != "Base" }
        #expect(languages.contains("ja"), "\(bundle.bundlePath) lists \(languages)")
        let missing = "\u{0}missing"
        for language in languages {
            let table = try #require(bundle.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)),
                                     "\(bundle.bundlePath) has no \(language).lproj")
            for key in ["cloud.upload.failed", "cloud.upload.refused"] {
                let text = table.localizedString(forKey: key, value: missing, table: "Cloud")
                if text == missing {
                    #expect(key != "cloud.upload.failed", "\(language) has no \(key)")
                    continue
                }
                #expect(!text.contains("%"), "\(language) \(key): \(text)")
                #expect(text.rangeOfCharacter(from: .decimalDigits) == nil, "\(language) \(key): \(text)")
            }
        }
        #expect(!CloudUploadStrings.failed.contains("%"))
        #expect(CloudUploadStrings.failed.rangeOfCharacter(from: .decimalDigits) == nil)
    }

    /// A Cloud chat started with no folder is no moved chat; its tab on the machine still takes the
    /// person's files when it is that machine's chat bound to the session asking
    /// (``DaemonStore/holdsChat(tab:host:session:)``), and no other tab does.
    @Test func aHomeCloudChatsTabTakesUploadsOnlyForItsOwnSession() throws {
        let store = DaemonStore()
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:cloud-1", session: "s1", harness: "claude"))
        let terminal = TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .pty, cwd: nil)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat, terminal])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "cloud", screens: [screen])]))
        let tabs = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs)
        let (chatTab, terminalTab) = (tabs[0].id, tabs[1].id)
        #expect(store.holdsChat(tab: chatTab, host: "registry:cloud-1", session: "s1"))
        #expect(!store.holdsChat(tab: chatTab, host: "registry:cloud-1", session: "s2"), "another chat's session")
        #expect(!store.holdsChat(tab: chatTab, host: "registry:cloud-2", session: "s1"), "another machine's chat")
        #expect(!store.holdsChat(tab: terminalTab, host: "registry:cloud-1", session: "s1"), "not a chat")
        #expect(!store.holdsChat(tab: "missing", host: "registry:cloud-1", session: "s1"))
    }
}
