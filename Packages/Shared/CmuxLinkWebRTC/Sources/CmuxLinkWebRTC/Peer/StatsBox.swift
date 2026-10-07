import CmuxLink
import Foundation
@preconcurrency import WebRTC

/// One `getStats` report, read for the selected candidate pair.
struct StatsBox: @unchecked Sendable {
    let report: RTCStatisticsReport

    func selectedPair() -> (local: CandidateType, remote: CandidateType, rtt: Duration?)? {
        let stats = report.statistics
        var pairID = stats.values.first { $0.type == "transport" }?.values["selectedCandidatePairId"] as? String
        if pairID == nil {
            pairID = stats.values.first { entry in
                entry.type == "candidate-pair"
                    && (entry.values["state"] as? String) == "succeeded"
                    && ((entry.values["nominated"] as? NSNumber)?.boolValue ?? false)
            }?.id
        }
        guard let pairID, let pair = stats[pairID],
              let localID = pair.values["localCandidateId"] as? String,
              let remoteID = pair.values["remoteCandidateId"] as? String,
              let localType = (stats[localID]?.values["candidateType"] as? String).flatMap(CandidateType.init(rawValue:)),
              let remoteType = (stats[remoteID]?.values["candidateType"] as? String).flatMap(CandidateType.init(rawValue:))
        else { return nil }
        let rtt = (pair.values["currentRoundTripTime"] as? NSNumber).map { Duration.seconds($0.doubleValue) }
        return (localType, remoteType, rtt)
    }
}
