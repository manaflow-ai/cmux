@testable import CmuxNextAgentActivity
import Foundation
import Testing

/// The Activity page's frame viewer reads each screenshot the helper kept: the host's stored bytes
/// go to the page as a `data:` URL (no decode or PNG re-encode on the main actor), and the viewer's
/// `full` size is asked for only when the session records full frames, else the thumbnail.
@MainActor
struct AgentActivityFramesTests {
    @Test func aSessionRecordSaysWhatItStores() {
        let read = { (recording: Any?) in
            var json: [String: Any] = ["id": "s"]
            json["recording"] = recording
            return AgentActivityWire.session(json, machine: "local", machineName: "This Mac")?.recording
        }
        #expect(read(nil) == .events)
        #expect(read("events") == .events)
        #expect(read("events+frames") == .eventsAndFrames)
        #expect(read("video") == .video)
        #expect(read("later") == .events)
    }

    @Test func fullFramesAreAskedForOnlyWhereTheHostKeepsThem() {
        #expect(AgentActivityWire.frameSize(requested: .full, recording: .events) == .thumb)
        #expect(AgentActivityWire.frameSize(requested: .full, recording: nil) == .thumb)
        #expect(AgentActivityWire.frameSize(requested: .full, recording: .eventsAndFrames) == .full)
        #expect(AgentActivityWire.frameSize(requested: .full, recording: .video) == .full)
        #expect(AgentActivityWire.frameSize(requested: .thumb, recording: .video) == .thumb)
    }

    @Test func theHostsBytesReachThePageUntouched() {
        #expect(AgentActivityWire.frameData(["mime": "image/jpeg", "data_base64": "/9j/AA=="])?.dataURL
            == "data:image/jpeg;base64,/9j/AA==")
        #expect(AgentActivityWire.frameData(["data_base64": "/9j/AA=="])?.mime == "image/jpeg")
        #expect(AgentActivityWire.frameData(["mime": "image/png", "data_base64": ""]) == nil)
        #expect(AgentActivityWire.frameData(["mime": "text/html", "data_base64": "PGI+"]) == nil)
        #expect(AgentActivityWire.frameData(["mime": "image/png;x=1", "data_base64": "AA=="]) == nil)
        #expect(AgentActivityWire.frameArgs(blob: "b.jpg", size: .full, session: "s") as NSDictionary
            == ["blob": "b.jpg", "size": "full", "id": "s"] as NSDictionary)
    }

    @Test func aFullFrameTheHostCannotFindFallsBackToTheThumbnail() async {
        var sent: [[String: Any]] = []
        let source = AgentActivitySocketSource(configuration: { Self.configuration }, send: { _, method, args in
            #expect(method == "activity_frame")
            sent.append(args)
            guard args["size"] as? String == "thumb" else { throw AgentActivitySourceError.refused("no full frame") }
            return ["mime": "image/jpeg", "data_base64": "dGh1bWI="]
        })
        let data = await source.frame(AgentActivityFrameRef(blob: "b.jpg", width: 180, height: 319), size: .full, session: "s")
        #expect(data?.dataURL == "data:image/jpeg;base64,dGh1bWI=")
        #expect(sent.map { $0["size"] as? String } == ["full", "thumb"])
        #expect(sent.allSatisfy { $0["id"] as? String == "s" && $0["blob"] as? String == "b.jpg" })
    }

    @Test func thePagesFrameRequestAsksForTheSizeTheSessionStores() async {
        var sizes: [String?] = []
        let source = AgentActivitySocketSource(configuration: { Self.configuration }, send: { _, method, args in
            // Selecting a session also asks for its timeline; only frame reads count here.
            guard method == "activity_frame" else { return [:] }
            sizes.append(args["size"] as? String)
            return ["mime": "image/jpeg", "data_base64": "AA=="]
        })
        let model = AgentActivityModel(source: source)
        model.apply(.sessions(machine: "local", [Self.session("thumbs", .events), Self.session("frames", .eventsAndFrames)]))
        let requests = AgentActivityRequests(model: model, source: source)

        let thumbs = await requests.reply(to: "frame", params: ["blob": "a.jpg", "size": "full", "session": "thumbs"])
        #expect(thumbs["ok"] as? Bool == true)
        #expect(thumbs["value"] as? String == "data:image/jpeg;base64,AA==")
        #expect(sizes == ["thumb"])

        _ = await requests.reply(to: "frame", params: ["blob": "a.jpg", "size": "full", "session": "frames"])
        #expect(sizes == ["thumb", "full"])

        _ = await requests.reply(to: "frame", params: ["blob": "a.jpg", "session": "frames"])
        #expect(sizes == ["thumb", "full", "thumb"])
    }

    @Test func aFrameTheHostDoesNotHaveIsAnError() async {
        let source = AgentActivitySocketSource(configuration: { Self.configuration }, send: { _, _, _ in
            throw AgentActivitySourceError.refused("unknown blob")
        })
        let requests = AgentActivityRequests(model: AgentActivityModel(source: source), source: source)
        let reply = await requests.reply(to: "frame", params: ["blob": "gone.jpg", "size": "thumb"])
        #expect(reply["ok"] as? Bool == false)
    }

    @Test func openingAFrameSelectsItsSessionAndThatFrameInOneRequest() async {
        let source = AgentActivitySocketSource(configuration: { Self.configuration }, send: { _, _, _ in [:] })
        let model = AgentActivityModel(source: source)
        model.apply(.sessions(machine: "local", [Self.session("a", .events), Self.session("b", .events)]))
        let frame = AgentActivityFrameRef(blob: "f.jpg", width: 180, height: 319)
        let events = (0..<4).map { seq in
            AgentActivityEvent(seq: UInt64(seq), time: Date(timeIntervalSince1970: Double(seq)), kind: .act, tool: "click",
                               afterFrame: frame)
        }
        model.apply(.events(session: "b", events))
        let requests = AgentActivityRequests(model: model, source: source)
        let reply = await requests.reply(to: "open", params: ["id": "b", "seq": 1])
        #expect(reply["ok"] as? Bool == true)
        #expect(model.selectedSessionID == "b")
        #expect(model.scrubSeq == 1)
        #expect(model.currentFrameEvent?.seq == 1)
    }

    private static let configuration = AgentActivitySocketSource.Configuration(socketPath: "/missing/cua.sock",
                                                                               machineName: "This Mac")

    private static func session(_ id: String, _ recording: AgentActivityRecording) -> AgentActivitySession {
        AgentActivitySession(id: id, machine: "local", machineName: "This Mac", label: id, agentKind: "claude",
                             agentName: "Claude Code", attribution: .credential, colorHex: "#30A46C", status: .active,
                             startedAt: Date(timeIntervalSince1970: 0), lastActionAt: Date(timeIntervalSince1970: 0),
                             recording: recording)
    }
}
