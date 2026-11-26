import CmuxMobilePairedMac
import Foundation

struct SecondaryMacEstablishmentFlight {
    let id: UUID
    let mac: MobilePairedMac
    let task: Task<SecondaryMacEstablishmentOutcome, Never>
}
