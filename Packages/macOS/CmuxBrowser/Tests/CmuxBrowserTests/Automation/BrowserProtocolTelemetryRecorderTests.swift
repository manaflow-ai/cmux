import Foundation
import Testing

@testable import CmuxBrowser

@Suite("DevTools protocol telemetry recorder")
struct BrowserProtocolTelemetryRecorderTests {
    @Test("A request records its response and its end in one entry")
    func requestLifecycle() throws {
        var recorder = BrowserProtocolTelemetryRecorder()
        #expect(recorder.ingest(#"{"method":"Network.requestWillBeSent","params":{"requestId":"r1","type":"Fetch","wallTime":1700000000.5,"timestamp":10.0,"request":{"url":"http://a.test/api","method":"POST","headers":{}}}}"#))
        #expect(recorder.networkRequests.first?.state == .pending)
        recorder.ingest(#"{"method":"Network.responseReceived","params":{"requestId":"r1","timestamp":10.1,"response":{"url":"http://a.test/api","status":201,"statusText":"Created","mimeType":"application/json","remoteIPAddress":"127.0.0.1","fromDiskCache":false}}}"#)
        recorder.ingest(#"{"method":"Network.loadingFinished","params":{"requestId":"r1","timestamp":10.25,"encodedDataLength":42}}"#)
        let request = try #require(recorder.networkRequests.first)
        #expect(recorder.networkRequests.count == 1)
        #expect(request.url == "http://a.test/api")
        #expect(request.method == "POST")
        #expect(request.resourceType == "fetch")
        #expect(request.status == 201)
        #expect(request.mimeType == "application/json")
        #expect(request.state == .finished)
        #expect(request.encodedDataLength == 42)
        #expect(request.timestampMS == 1_700_000_000_500)
        #expect(abs((request.durationMS ?? 0) - 250) < 0.001)
        let json = request.jsonObject
        #expect(json["request_id"] as? String == "r1")
        #expect(json["status"] as? Int == 201)
        #expect(json["state"] as? String == "finished")
    }

    @Test("A failed request keeps its error text")
    func failedRequest() throws {
        var recorder = BrowserProtocolTelemetryRecorder()
        recorder.ingest(#"{"method":"Network.requestWillBeSent","params":{"requestId":"r2","type":"Document","wallTime":1,"timestamp":1,"request":{"url":"http://gone.test/","method":"GET"}}}"#)
        recorder.ingest(#"{"method":"Network.loadingFailed","params":{"requestId":"r2","timestamp":2,"errorText":"net::ERR_INTERNET_DISCONNECTED","canceled":false}}"#)
        let request = try #require(recorder.networkRequests.first)
        #expect(request.state == .failed)
        #expect(request.errorText == "net::ERR_INTERNET_DISCONNECTED")
        #expect(request.jsonObject["error_text"] as? String == "net::ERR_INTERNET_DISCONNECTED")
    }

    @Test("A redirect closes the hop with its status and opens the next one")
    func redirect() {
        var recorder = BrowserProtocolTelemetryRecorder()
        recorder.ingest(#"{"method":"Network.requestWillBeSent","params":{"requestId":"r3","type":"Document","wallTime":1,"timestamp":1,"request":{"url":"http://a.test/old","method":"GET"}}}"#)
        recorder.ingest(#"{"method":"Network.requestWillBeSent","params":{"requestId":"r3","type":"Document","wallTime":2,"timestamp":2,"request":{"url":"http://a.test/new","method":"GET"},"redirectResponse":{"url":"http://a.test/old","status":302,"statusText":"Found"}}}"#)
        recorder.ingest(#"{"method":"Network.responseReceived","params":{"requestId":"r3","timestamp":3,"response":{"url":"http://a.test/new","status":200}}}"#)
        let requests = recorder.networkRequests
        #expect(requests.map(\.url) == ["http://a.test/old", "http://a.test/new"])
        #expect(requests.map(\.state) == [.redirected, .pending])
        #expect(requests.map(\.status) == [302, 200])
    }

    @Test("Network requests are bounded, oldest first out")
    func boundedRequests() {
        var recorder = BrowserProtocolTelemetryRecorder()
        for index in 0..<(BrowserProtocolTelemetryRecorder.networkRequestLimit + 3) {
            recorder.ingest(#"{"method":"Network.requestWillBeSent","params":{"requestId":"r\#(index)","type":"XHR","wallTime":1,"timestamp":1,"request":{"url":"http://a.test/\#(index)","method":"GET"}}}"#)
        }
        #expect(recorder.networkRequests.count == BrowserProtocolTelemetryRecorder.networkRequestLimit)
        #expect(recorder.networkRequests.first?.requestID == "r3")
        // A late event of a dropped request is ignored.
        recorder.ingest(#"{"method":"Network.loadingFinished","params":{"requestId":"r0","timestamp":2}}"#)
        #expect(recorder.networkRequests.first?.requestID == "r3")
    }

    @Test("Console API calls become console entries in the bootstrap's shape")
    func consoleEntries() throws {
        var recorder = BrowserProtocolTelemetryRecorder()
        recorder.ingest(#"{"method":"Runtime.consoleAPICalled","params":{"type":"log","timestamp":1700000000123.5,"executionContextId":1,"args":[{"type":"string","value":"fixture-console-log"},{"type":"number","value":3,"description":"3"}]}}"#)
        recorder.ingest(#"{"method":"Runtime.consoleAPICalled","params":{"type":"warning","timestamp":2,"args":[{"type":"object","className":"Object","description":"Object","preview":{"type":"object","overflow":false,"properties":[{"name":"a","type":"number","value":"1"},{"name":"b","type":"string","value":"x"}]}}]}}"#)
        recorder.ingest(#"{"method":"Runtime.consoleAPICalled","params":{"type":"endGroup","timestamp":3,"args":[]}}"#)
        #expect(recorder.consoleEntries.map(\.level) == ["log", "warn"])
        #expect(recorder.consoleEntries.map(\.text) == ["fixture-console-log 3", #"{"a":1,"b":"x"}"#])
        let json = try #require(recorder.consoleEntries.first?.jsonObject)
        #expect(json["level"] as? String == "log")
        #expect(json["text"] as? String == "fixture-console-log 3")
        #expect(json["timestamp_ms"] as? Double == 1_700_000_000_123.5)
    }

    @Test("Uncaught exceptions become page errors; a revoked one is removed")
    func pageErrors() throws {
        var recorder = BrowserProtocolTelemetryRecorder()
        recorder.ingest(#"{"method":"Runtime.exceptionThrown","params":{"timestamp":5,"exceptionDetails":{"exceptionId":7,"text":"Uncaught","lineNumber":41,"columnNumber":24,"url":"http://a.test/index.html","exception":{"type":"object","subtype":"error","className":"Error","description":"Error: fixture-page-error\n    at http://a.test/index.html:42:25"}}}}"#)
        recorder.ingest(#"{"method":"Runtime.exceptionThrown","params":{"timestamp":6,"exceptionDetails":{"exceptionId":8,"text":"Uncaught (in promise)","lineNumber":0,"columnNumber":0,"exception":{"type":"string","value":"nope"}}}}"#)
        let error = try #require(recorder.pageErrors.first)
        #expect(error.message == "Uncaught Error: fixture-page-error")
        #expect(error.source == "http://a.test/index.html")
        #expect(error.line == 42)
        #expect(error.column == 25)
        #expect(recorder.pageErrors.last?.message == "Uncaught (in promise) nope")
        recorder.ingest(#"{"method":"Runtime.exceptionRevoked","params":{"reason":"Handler added to rejected promise","exceptionId":8}}"#)
        #expect(recorder.pageErrors.map(\.message) == ["Uncaught Error: fixture-page-error"])
        #expect(error.jsonObject["message"] as? String == "Uncaught Error: fixture-page-error")
        #expect(error.jsonObject["line"] as? Int == 42)
    }

    @Test("A new main document clears console entries and errors, not requests")
    func navigationClearsLogs() {
        var recorder = BrowserProtocolTelemetryRecorder()
        recorder.ingest(#"{"method":"Network.requestWillBeSent","params":{"requestId":"r1","type":"Document","wallTime":1,"timestamp":1,"request":{"url":"http://a.test/","method":"GET"}}}"#)
        recorder.ingest(#"{"method":"Runtime.consoleAPICalled","params":{"type":"log","timestamp":1,"args":[{"type":"string","value":"old"}]}}"#)
        recorder.ingest(#"{"method":"Runtime.exceptionThrown","params":{"timestamp":1,"exceptionDetails":{"exceptionId":1,"text":"Uncaught","lineNumber":0,"columnNumber":0}}}"#)
        recorder.ingest(#"{"method":"Runtime.executionContextsCleared","params":{}}"#)
        #expect(recorder.consoleEntries.isEmpty)
        #expect(recorder.pageErrors.isEmpty)
        #expect(recorder.networkRequests.count == 1)
    }

    @Test("Replies, unknown events and malformed messages are ignored")
    func ignoredMessages() {
        var recorder = BrowserProtocolTelemetryRecorder()
        #expect(!recorder.ingest(#"{"id":1073741824,"result":{}}"#))
        #expect(!recorder.ingest(#"{"method":"Network.dataReceived","params":{"requestId":"r1","dataLength":10}}"#))
        #expect(!recorder.ingest(#"{"method":"Runtime.consoleAPICalled""#))
        #expect(!recorder.ingest(""))
        #expect(recorder.consoleEntries.isEmpty && recorder.networkRequests.isEmpty)
    }

    @Test("Clearing one log leaves the others")
    func clearing() {
        var recorder = BrowserProtocolTelemetryRecorder()
        recorder.ingest(#"{"method":"Runtime.consoleAPICalled","params":{"type":"log","timestamp":1,"args":[{"type":"string","value":"a"}]}}"#)
        recorder.ingest(#"{"method":"Runtime.exceptionThrown","params":{"timestamp":1,"exceptionDetails":{"exceptionId":1,"text":"Uncaught","lineNumber":0,"columnNumber":0}}}"#)
        recorder.clearConsole()
        #expect(recorder.consoleEntries.isEmpty)
        #expect(recorder.pageErrors.count == 1)
        recorder.clearErrors()
        #expect(recorder.pageErrors.isEmpty)
    }
}

@Suite("DevTools protocol telemetry merge")
struct BrowserProtocolTelemetryMergeTests {
    private func entry(_ text: String, at time: Double, level: String = "log") -> BrowserProtocolConsoleEntry {
        BrowserProtocolConsoleEntry(level: level, text: text, timestampMS: time)
    }

    @Test("Without protocol recording the bootstrap's entries are returned as is")
    func scriptOnly() {
        let script: [[String: Any]] = [["level": "log", "text": "a", "timestamp_ms": 1.0]]
        let merged = BrowserProtocolTelemetryMerge.consoleItems(protocolEntries: [], scriptItems: script, recordingStartedAtMS: nil)
        #expect(merged.map { $0["text"] as? String } == ["a"])
    }

    @Test("An entry both sources saw appears once")
    func noDuplicates() {
        let script: [[String: Any]] = [
            ["level": "log", "text": "fixture-console-log", "timestamp_ms": 100.0],
            ["level": "log", "text": "after", "timestamp_ms": 300.0],
        ]
        let protocolEntries = [entry("fixture-console-log", at: 101), entry("after", at: 301)]
        let merged = BrowserProtocolTelemetryMerge.consoleItems(
            protocolEntries: protocolEntries, scriptItems: script, recordingStartedAtMS: 200
        )
        #expect(merged.map { $0["text"] as? String } == ["fixture-console-log", "after"])
    }

    @Test("Bootstrap entries from before recording that the protocol missed are kept, in time order")
    func keepsEarlierScriptOnlyEntries() {
        let script: [[String: Any]] = [
            ["level": "info", "text": "early", "timestamp_ms": 50.0],
            ["level": "log", "text": "only-script-late", "timestamp_ms": 400.0],
        ]
        let merged = BrowserProtocolTelemetryMerge.consoleItems(
            protocolEntries: [entry("frame-log", at: 120)], scriptItems: script, recordingStartedAtMS: 200
        )
        #expect(merged.map { $0["text"] as? String } == ["early", "frame-log"])
    }

    @Test("A page error both sources saw appears once")
    func errorsNoDuplicates() {
        let script: [[String: Any]] = [
            ["message": "Uncaught Error: fixture-page-error", "source": "s", "line": 1, "column": 1, "timestamp_ms": 10.0],
            ["message": "nope", "source": "unhandledrejection", "line": 0, "column": 0, "timestamp_ms": 11.0],
        ]
        let protocolErrors = [
            BrowserProtocolPageError(message: "Uncaught Error: fixture-page-error", source: "s", line: 1, column: 1, timestampMS: 10),
            BrowserProtocolPageError(message: "Uncaught (in promise) nope", source: "", line: 0, column: 0, timestampMS: 11),
        ]
        let merged = BrowserProtocolTelemetryMerge.errorItems(
            protocolErrors: protocolErrors, scriptItems: script, recordingStartedAtMS: 500
        )
        #expect(merged.map { $0["message"] as? String } == ["Uncaught Error: fixture-page-error", "Uncaught (in promise) nope"])
    }
}
