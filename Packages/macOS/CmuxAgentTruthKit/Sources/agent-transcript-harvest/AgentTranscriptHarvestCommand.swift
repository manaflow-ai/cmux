import CmuxAgentTranscriptHarvest
import Foundation

@main
struct AgentTranscriptHarvestCommand {
    static func main() {
        do {
            let arguments = try TranscriptHarvestArguments.parse(CommandLine.arguments)
            let scanner = TranscriptHarvestScanner()
            let result = scanner.scan(
                claudeRoot: arguments.claudeRoot,
                codexRoot: arguments.codexRoot,
                maxFiles: arguments.maxFiles,
                modifiedSince: arguments.modifiedSince
            )
            let formatter = TranscriptHarvestFormatter()
            let output = try arguments.format == .json ? formatter.json(result) : formatter.tsv(result)
            FileHandle.standardOutput.write(Data((output + "\n").utf8))
        } catch TranscriptHarvestArgumentError.help {
            FileHandle.standardOutput.write(Data((TranscriptHarvestArgumentError.help.description + "\n").utf8))
        } catch {
            FileHandle.standardError.write(Data("agent-transcript-harvest: \(error)\n".utf8))
            Foundation.exit(2)
        }
    }
}
