import ArgumentParser
import Foundation

struct DumpCommandTree: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__dump-command-tree",
        shouldDisplay: false
    )

    func run() throws {
        try GlobalOptions().makeCLI().runDumpCommandTree()
    }
}
