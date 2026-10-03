import Foundation
import Testing
@testable import CmuxNextApps

/// The Swift side reads the same scope table as the Rust validator: the
/// bundled copy is byte-identical to the source (sync-app-runtime.sh
/// --check enforces it in check-app-platform.sh), and these cases match
/// `every_scope_in_the_grammar_has_a_class` in cmux-app-manifest.
@Suite struct AppScopeClassTableTests {
    @Test func theBundledTableIsTheValidatorsTable() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "../../../cmux-tui/crates/cmux-app-host/schema/v2/scope-classes.json").standardizedFileURL
        #expect(try Data(contentsOf: AppPlatformResources.scopeClassesFile) == Data(contentsOf: source))
    }

    @Test func classesMatchTheRustValidatorCases() {
        let table = AppScopeClassTable.bundled
        let cases: [(String, AppScopeClassTable.ScopeClass, Bool)] = [
            ("git:read", .standard, false), ("integration:github:read", .standard, false),
            ("embed:run", .standard, false), ("storage:synced", .standard, false),
            ("git:write", .sensitive, false), ("host:control", .sensitive, false),
            ("agent_cli:execute", .sensitive, false), ("net:*.github.com", .sensitive, false),
            ("actions:run", .sensitive, false),
            ("feed:answer", .restricted, false), ("terminal:input", .restricted, false),
            ("fs:write", .restricted, false), ("usage:read", .restricted, false),
            ("mcp:expose", .restricted, false), ("clipboard:write", .restricted, false),
            ("coderouter:keys", .restricted, false),
            ("process:spawn:sr", .restricted, true), ("op:coderouter.accounts.usage", .sensitive, true),
        ]
        for (scope, scopeClass, serverOnly) in cases {
            let rule = table.rule(for: scope)
            #expect(rule?.scopeClass == scopeClass && rule?.serverOnly == serverOnly, "\(scope)")
        }
    }

    @Test func unknownScopesAreRestricted() {
        #expect(AppScopeClassTable.bundled.scopeClass(of: "nonsense") == nil)
        #expect(AppScopeClassTable.bundled.isRestricted("nonsense"))
        #expect(AppScopeClassTable(rules: []).isRestricted("git:read"))
    }
}
