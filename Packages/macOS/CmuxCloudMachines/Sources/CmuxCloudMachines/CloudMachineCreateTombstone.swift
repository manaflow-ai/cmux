import Foundation

/// A stopped create's receipt buffer, kept until its process terminates.
struct CloudMachineCreateTombstone {
    /// Output after the last complete line, for a receipt split across chunks.
    var carry: String
    /// The machine a deletion owns. A receipt naming it never requests cleanup.
    let sparedMachineID: String?

    /// Whether a receipt naming the machine should destroy it.
    /// - Parameter machineID: The machine the stopped create's receipt named.
    func cleansUp(_ machineID: String) -> Bool { machineID != sparedMachineID }
}
