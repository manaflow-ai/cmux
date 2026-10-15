import Foundation
import Testing
@testable import CmuxCEFBrowser

@MainActor
@Suite("Chromium renderer process resolver")
struct CEFRendererProcessResolverTests {
    private static let helper = "/Applications/cmux.app/Contents/Frameworks/cmux Helper (Renderer).app/Contents/MacOS/cmux Helper (Renderer)"

    @Test("Reads the renderer client id of tab renderers only")
    func parsesArgv() {
        #expect(CEFRendererProcessResolver.rendererClientID([Self.helper, "--type=renderer", "--renderer-client-id=7"]) == 7)
        #expect(CEFRendererProcessResolver.rendererClientID(
            [Self.helper, "--type=renderer", "--extension-process", "--renderer-client-id=8"]) == nil)
        #expect(CEFRendererProcessResolver.rendererClientID([Self.helper, "--type=gpu-process"]) == nil)
        #expect(CEFRendererProcessResolver.rendererClientID([Self.helper, "--type=renderer"]) == nil)
        #expect(CEFRendererProcessResolver.rendererClientID(["/bin/zsh", "-l"]) == nil)
    }

    @Test("Finds the helper of a client id, reads argv once per pid, and forgets exited helpers")
    func resolvesAndCaches() {
        var children: [Int32] = [100, 101, 102]
        var reads: [Int32: Int] = [:]
        let argv: [Int32: [String]] = [
            100: [Self.helper, "--type=gpu-process"],
            101: [Self.helper, "--type=renderer", "--renderer-client-id=3"],
            102: [Self.helper, "--type=renderer", "--renderer-client-id=4"],
            103: [Self.helper, "--type=renderer", "--renderer-client-id=3"],
        ]
        let resolver = CEFRendererProcessResolver(
            parent: 1,
            children: { _ in children },
            arguments: { pid in
                reads[pid, default: 0] += 1
                return argv[pid] ?? []
            }
        )
        #expect(resolver.pid(forRendererClientID: 4) == 102)
        #expect(resolver.pid(forRendererClientID: 3) == 101)
        #expect(resolver.pid(forRendererClientID: 9) == nil)
        #expect(reads == [100: 1, 101: 1, 102: 1])

        // Renderer 101 exited and Chromium started 103 for the same client id.
        children = [100, 102, 103]
        #expect(resolver.pid(forRendererClientID: 3) == 103)
        #expect(reads[103] == 1)
    }

    @Test("A child that has not exec'd yet is read again")
    func retriesUnexecdChild() {
        var argv: [String] = ["/Applications/cmux.app/Contents/MacOS/cmux"]
        var reads = 0
        let resolver = CEFRendererProcessResolver(parent: 1, children: { _ in [200] }, arguments: { _ in
            reads += 1
            return argv
        })
        #expect(resolver.pid(forRendererClientID: 5) == nil)
        argv = [Self.helper, "--type=renderer", "--renderer-client-id=5"]
        #expect(resolver.pid(forRendererClientID: 5) == 200)
        #expect(reads == 2)
    }
}
