import CmuxLink
import CmuxLinkWebRTC
import Testing

@Suite("Path classification")
struct PathTests {
    static let lines: [(String, CandidateType)] = [
        ("candidate:1 1 udp 2122260223 192.168.1.20 54321 typ host generation 0", .host),
        ("candidate:2 1 udp 1686052607 203.0.113.7 61000 typ srflx raddr 192.168.1.20 rport 54321", .srflx),
        ("candidate:3 1 udp 1845501695 203.0.113.9 62000 typ prflx raddr 0.0.0.0 rport 0", .prflx),
        ("candidate:4 1 udp 41885439 104.30.1.1 3478 typ relay raddr 203.0.113.7 rport 61000", .relay),
    ]

    @Test("candidate types parse from candidate lines")
    func parsesTypes() {
        for (line, type) in Self.lines { #expect(CandidateType(candidateLine: line) == type) }
        #expect(CandidateType(candidateLine: "candidate:5 1 udp 1 10.0.0.1 9 typ") == nil)
        #expect(CandidateType(candidateLine: "garbage") == nil)
    }

    @Test("a relay on either end is TURN; everything else is P2P")
    func classifies() {
        let classifier = CandidatePairClassifier()
        for local in CandidateType.allCases {
            for remote in CandidateType.allCases {
                let expected: PathKind = local == .relay || remote == .relay ? .turn : .p2p
                #expect(classifier.kind(local: local, remote: remote) == expected)
            }
        }
        #expect(classifier.kind(localLine: Self.lines[0].0, remoteLine: Self.lines[3].0) == .turn)
        #expect(classifier.kind(localLine: Self.lines[1].0, remoteLine: Self.lines[2].0) == .p2p)
        #expect(classifier.kind(localLine: "x", remoteLine: Self.lines[0].0) == nil)
    }

    @Test("steady-state RTT sampling is enabled by default and explicitly disableable")
    func rttSamplingPolicy() {
        #expect(WebRTCConfiguration().rttSampleInterval == .seconds(1))
        #expect(WebRTCConfiguration(rttSampleInterval: nil).rttSampleInterval == nil)
    }

    @Test("lane labels round trip and clamp partial lifetimes")
    func laneLabels() {
        let lanes = [
            TransportLane.control,
            TransportLane(reliability: .reliableOrdered, priority: .bulk),
            TransportLane(reliability: .unreliableUnordered, priority: .media),
            TransportLane(reliability: .partial(maxLifetime: .milliseconds(250)), priority: .render),
        ]
        for lane in lanes {
            let label = LaneLabel(lane: lane)
            #expect(LaneLabel(label: label.label)?.lane == lane, "\(label.label)")
        }
        #expect(LaneLabel(lane: lanes[3]).label == "cmux/1 p250 render")
        #expect(LaneLabel(lane: TransportLane(reliability: .partial(maxLifetime: .seconds(600)), priority: .media)).maxPacketLifeTimeMs == 65535)
        #expect(LaneLabel(lane: TransportLane(reliability: .partial(maxLifetime: .microseconds(10)), priority: .media)).maxPacketLifeTimeMs == 1)
        #expect(LaneLabel(label: LaneLabel.control) == nil)
        #expect(LaneLabel(label: "chat") == nil)
        #expect(LaneLabel(label: "cmux/1 x input") == nil)
    }
}
