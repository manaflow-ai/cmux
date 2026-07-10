import Foundation

extension CmuxTaskManagerCodingAgentDefinition {
    static let campfire = Self(
        id: "campfire",
        displayName: "Campfire",
        assetName: nil,
        launchKinds: ["campfire"],
        directBasenames: ["campfire"],
        argumentNeedles: ["packages/session/bin/campfire.ts", "packages/session/dist/campfire"]
    )

    static let argumentHostBasenames: Set<String> = [
        "node", "bun", "deno", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node"
    ]
}
