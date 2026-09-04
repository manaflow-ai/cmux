import Darwin
import Foundation
import Testing
@testable import CmuxBrowser

/// Opt-in because these tests download and launch the pinned browser. Run on
/// a leased Mac with CMUX_TEST_CHROMIUM_RUNTIME=1, never a user's GUI session.
@Suite("Chromium real runtime", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_CHROMIUM_RUNTIME"] == "1"))
struct ChromiumRuntimeIntegrationTests {
    @Test("Pinned runtime renders, accepts input, navigates and restarts",
          .timeLimit(.minutes(2)), arguments: [0, 1, 2])
    func liveSession(mode: Int) async throws {
        let loopback = mode != 0
        let withExtensions = mode == 2
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chromium-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let environment = ChromiumBrowserRuntimeEnvironment(
            fileManager: .default,
            runtimeDownloadSession: network,
            loopbackCDPSession: network,
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.cmux.chromium.integration" },
            executableOverrideProvider: { nil },
            startupDeadline: { try await ContinuousClock().sleep(for: .seconds(15)) }
        )
        let extensionDirectory = root.appendingPathComponent("fixture-extension")
        if withExtensions { try Self.writeExtension(to: extensionDirectory) }
        let port = loopback ? try await ChromiumLoopbackPortAllocator().allocate() : 0
        let session = ChromiumBrowserSession(
            profileID: UUID(),
            remoteDebuggingPort: try #require(ChromiumRemoteDebuggingPort(rawValue: port)),
            environment: environment,
            extensionDirectories: withExtensions ? [extensionDirectory.path] : []
        )
        do {
            try await session.start()
            let process = try #require(await session.process)
            let pid = process.processIdentifier
            let endpoint = await session.externallyVisibleEndpoint()
            #expect((endpoint != nil) == loopback)
            if loopback {
                let browserSocket = try await ChromiumCDPEndpointDiscovery(session: network)
                    .browserWebSocketURL(port: port)
                #expect(browserSocket.host == "127.0.0.1")
                let external = try ChromiumCDPConnection(endpoint: browserSocket, session: network)
                try await external.connect()
                let version = try await external.send(method: "Browser.getVersion")
                guard case .object(let versionFields) = version else {
                    throw CDPError.malformedMessage
                }
                #expect(versionFields["product"]?.stringValue?.contains(ChromiumRuntimeManifest.production.version) == true)
                await external.shutdown()
            }
            let frames = await session.frames()
            let firstFrame = Task {
                for await frame in frames {
                    if Self.hasAspectRatio(frame, width: 640, height: 480) { return frame }
                }
                throw CDPError.malformedMessage
            }
            defer { firstFrame.cancel() }
            try await session.setViewport(width: 640, height: 480)
            let html = """
            <title>Chromium integration</title>
            <style>@keyframes pulse { from { background-color: #228833 } to { background-color: #33aa66 } }
            body { outline: 2px solid; animation: pulse 1s infinite alternate; }</style>
            <body style='margin:0;background:#228833'>
            <input id='field' style='position:absolute;left:20px;top:20px;width:200px;height:40px'>
            <button id='button' style='position:absolute;left:20px;top:100px;width:200px;height:40px'
              onclick='document.title="clicked"'>Click</button></body>
            """
            let server = try ChromiumHTTPFixture(html: html)
            defer { server.stop() }
            let url = try await server.start()
            try await session.navigate(to: url)
            try await session.waitForDocumentReady()
            #expect(try await session.evaluateJavaScript("document.title") == .string("Chromium integration"))
            if withExtensions {
                #expect(try await Self.extensionMarker(in: session) > 0)
                let targets = try await session.sendCommand(method: "Target.getTargets")
                #expect(String(describing: targets).contains("service_worker"))
            }
            for type in ["mousePressed", "mouseReleased"] {
                try await session.dispatchMouse(type: type, x: 40, y: 40, button: "left")
            }
            try await session.dispatchKey(type: "keyDown", key: "a", code: "KeyA", text: "a")
            try await session.dispatchKey(type: "keyUp", key: "a", code: "KeyA")
            try await session.insertText("日本語")
            #expect(try await session.evaluateJavaScript("field.value") == .string("a日本語"))
            try await session.dispatchKey(type: "keyDown", key: "Backspace", code: "Backspace")
            try await session.dispatchKey(type: "keyUp", key: "Backspace", code: "Backspace")
            #expect(try await session.evaluateJavaScript("field.value") == .string("a日本"))
            for type in ["mousePressed", "mouseReleased"] {
                try await session.dispatchMouse(type: type, x: 40, y: 120, button: "left")
            }
            #expect(try await session.evaluateJavaScript("document.title") == .string("clicked"))
            _ = try await session.sendCommand(method: "Network.setCookie", parameters: .object([
                "url": .string(url.absoluteString), "name": .string("cmux_fixture"),
                "value": .string("cookie-value"), "httpOnly": .bool(true),
            ]))
            let cookies = try await session.sendCommand(method: "Network.getAllCookies")
            #expect(String(describing: cookies).contains("cookie-value"))
            _ = try await session.sendCommand(method: "Page.addScriptToEvaluateOnNewDocument", parameters: .object([
                "source": .string("window.cmuxDocumentScript = 'document-start';"),
            ]))
            let resizedFrames = await session.frames()
            let matchingResize = Task {
                var matches = 0
                for await frame in resizedFrames {
                    if Self.hasAspectRatio(frame, width: 379, height: 610) {
                        matches += 1
                        if matches == 2 { return }
                    }
                }
                throw CDPError.malformedMessage
            }
            defer { matchingResize.cancel() }
            try await session.setViewport(width: 379, height: 610, deviceScaleFactor: 2)
            try await matchingResize.value
            #expect(try await session.evaluateJavaScript("[innerWidth,innerHeight,devicePixelRatio]") == .array([.number(379),.number(610),.number(2)]))
            let png = try await session.screenshotPNG()
            #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            #expect(png.count > 1000)
            #expect(try await firstFrame.value.starts(with: [137, 80, 78, 71]))
            let next = try #require(URL(string: "data:text/html,<title>Second</title>second"))
            try await session.navigate(to: next)
            try await session.waitForDocumentReady()
            #expect(try await session.evaluateJavaScript("window.cmuxDocumentScript") == .string("document-start"))
            try await session.goBack()
            try await session.waitForDocumentReady()
            #expect(try await session.evaluateJavaScript("location.href") == .string(url.absoluteString))
            try await session.goForward()
            try await session.waitForDocumentReady()
            #expect(try await session.evaluateJavaScript("document.title") == .string("Second"))
            for _ in 0..<8 {
                try await session.goBack()
                try await session.waitForDocumentReady()
                #expect(try await session.evaluateJavaScript("location.href") == .string(url.absoluteString))
                try await session.goForward()
                try await session.waitForDocumentReady()
                #expect(try await session.evaluateJavaScript("document.title") == .string("Second"))
            }
            await session.stopAndWait()
            #expect(kill(pid, 0) == -1)
            async let firstRestart: Void = session.start()
            async let joinedRestart: Void = session.start()
            _ = try await (firstRestart, joinedRestart)
            #expect(try await session.evaluateJavaScript("6 * 7") == .number(42))
            if withExtensions {
                try await session.navigate(to: url)
                try await session.waitForDocumentReady()
                #expect(try await Self.extensionMarker(in: session) > 1)
            }
        } catch {
            await session.stopAndWait()
            throw error
        }
        await session.stopAndWait()
    }

    private static func hasAspectRatio(_ png: Data, width: Int, height: Int) -> Bool {
        guard png.count >= 24 else { return false }
        let actualWidth = png[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let actualHeight = png[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return actualWidth > 0 && actualHeight > 0
            && abs(Double(actualHeight) - Double(actualWidth) * Double(height) / Double(width)) <= 2
    }

    private static func writeExtension(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"cmux fixture","version":"1.0","permissions":["storage"],"background":{"service_worker":"worker.js"},"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"]}]}"#
        let worker = """
        chrome.runtime.onMessage.addListener((message, sender, reply) => {
          chrome.storage.local.get({count:0}).then(async ({count}) => {
            await chrome.storage.local.set({count:count+1}); reply(count+1);
          }); return true;
        });
        """
        let content = """
        chrome.runtime.sendMessage({}, count => {
          document.documentElement.dataset.cmuxExtension = String(count);
        });
        """
        for (name, text) in [("manifest.json", manifest), ("worker.js", worker), ("content.js", content)] {
            try Data(text.utf8).write(to: root.appendingPathComponent(name))
        }
    }

    private static func extensionMarker(in session: ChromiumBrowserSession) async throws -> Double {
        let script = """
        new Promise((resolve,reject) => {
          const read=()=>Number(document.documentElement.dataset.cmuxExtension||0);
          if(read()) { resolve(read()); return; }
          const observer=new MutationObserver(()=>{if(read()){observer.disconnect();clearTimeout(timer);resolve(read());}});
          const timer=setTimeout(()=>{observer.disconnect();reject(new Error('MV3 marker missing'));},10000);
          observer.observe(document.documentElement,{attributes:true,attributeFilter:['data-cmux-extension']});
        })
        """
        return try await session.evaluateJavaScript(script).doubleValue ?? 0
    }
}
