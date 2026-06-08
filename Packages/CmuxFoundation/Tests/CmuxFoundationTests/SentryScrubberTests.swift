import Testing

@testable import CmuxFoundation

@Suite struct SentryScrubberTests {
    /// A scrubber with a fixed home directory so path redaction is deterministic.
    private let scrubber = SentryScrubber(homeDirectory: "/Users/lawrence")

    // MARK: - Paths

    @Test func redactsInjectedHomeDirectory() {
        #expect(
            scrubber.scrub("loaded /Users/lawrence/.config/cmux/cmux.json")
                == "loaded /Users/<redacted>/.config/cmux/cmux.json"
        )
    }

    @Test func redactsAnyUsersPathEvenWhenNotTheRuntimeHome() {
        // Stack frames carry the build machine's home, which is not the runtime
        // home dir; the generic /Users/<name>/ rule must still catch it.
        #expect(
            scrubber.scrub("/Users/buildbot/work/cmux/Sources/AppDelegate.swift")
                == "/Users/<redacted>/work/cmux/Sources/AppDelegate.swift"
        )
    }

    @Test func redactsLinuxHomePaths() {
        #expect(
            scrubber.scrub("at /home/runner/cmux/main.swift line 12")
                == "at /home/<redacted>/cmux/main.swift line 12"
        )
    }

    @Test func redactsMultipleDistinctUsernamesInOneString() {
        let input = "/Users/alice/a.txt and /Users/bob/b.txt"
        #expect(scrubber.scrub(input) == "/Users/<redacted>/a.txt and /Users/<redacted>/b.txt")
    }

    @Test func leavesSystemPathsUntouched() {
        let input = "/usr/lib/foo /System/Library/bar /Applications/cmux.app"
        #expect(scrubber.scrub(input) == input)
    }

    // MARK: - Emails

    @Test func redactsEmailAddresses() {
        #expect(
            scrubber.scrub("signed in as lawrence@cmux.com today")
                == "signed in as <redacted-email> today"
        )
    }

    @Test func redactsEmailWithPlusAndSubdomain() {
        #expect(
            scrubber.scrub("to a.b+tag@mail.example.co.uk failed")
                == "to <redacted-email> failed"
        )
    }

    // MARK: - Secrets

    @Test func redactsBearerToken() {
        #expect(
            scrubber.scrub("Authorization header Bearer abc123DEF456ghi789xyz")
                == "Authorization header Bearer <redacted-secret>"
        )
    }

    @Test func redactsTokenQueryParameterButKeepsKey() {
        #expect(
            scrubber.scrub("GET https://api.example.com/v1?token=supersecretvalue123&page=2")
                == "GET https://api.example.com/v1?token=<redacted-secret>&page=2"
        )
    }

    @Test func redactsPasswordAssignment() {
        #expect(
            scrubber.scrub(#"{"password":"hunter2hunter2hunter2"}"#)
                == #"{"password":"<redacted-secret>"}"#
        )
    }

    @Test func redactsProviderApiKey() {
        #expect(
            scrubber.scrub("using sk-proj-abcdef0123456789ABCDEF to call")
                == "using <redacted-secret> to call"
        )
    }

    @Test func redactsGitHubToken() {
        #expect(
            scrubber.scrub("clone with ghp_0123456789abcdefABCDEF0123456789abcd")
                == "clone with <redacted-secret>"
        )
    }

    @Test func redactsJsonWebToken() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(scrubber.scrub("session \(jwt) expired") == "session <redacted-secret> expired")
    }

    @Test func redactsAwsAccessKeyId() {
        #expect(
            scrubber.scrub("creds AKIAIOSFODNN7EXAMPLE rejected")
                == "creds <redacted-secret> rejected"
        )
    }

    @Test func redactsEnvStyleSecretAssignmentWithLongerKeyName() {
        // The sensitive marker is embedded in a longer env identifier.
        #expect(
            scrubber.scrub("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY done")
                == "AWS_SECRET_ACCESS_KEY=<redacted-secret> done"
        )
        #expect(
            scrubber.scrub("export MY_API_KEY=plainlettersvalue123")
                == "export MY_API_KEY=<redacted-secret>"
        )
    }

    // MARK: - Grouping fields preserved

    @Test func preservesNormalErrorText() {
        let input = "Fatal error: Index out of range while reading buffer"
        #expect(scrubber.scrub(input) == input)
    }

    @Test func preservesExceptionTypeShape() {
        // Exception type / function names must round-trip unchanged so Sentry
        // grouping is unaffected.
        let input = "NSInvalidArgumentException in -[NSArray objectAtIndex:]"
        #expect(scrubber.scrub(input) == input)
    }

    @Test func preservesShortIdentifiersThatAreNotSecrets() {
        let input = "code=42 status=ok retry=true id=ABC123"
        #expect(scrubber.scrub(input) == input)
    }

    @Test func emptyStringIsUnchanged() {
        #expect(scrubber.scrub("") == "")
    }

    // MARK: - Recursive value scrubbing

    @Test func scrubsNestedDictionaryValues() {
        let input: [String: Any] = [
            "cwd": "/Users/lawrence/dev/cmux",
            "email": "lawrence@cmux.com",
            "count": 7,
            "nested": ["url": "https://x.com/?token=abcdef0123456789secret"] as [String: Any],
        ]
        let output = scrubber.scrub(dictionary: input)
        #expect(output["cwd"] as? String == "/Users/<redacted>/dev/cmux")
        #expect(output["email"] as? String == "<redacted-email>")
        #expect(output["count"] as? Int == 7)
        let nested = output["nested"] as? [String: Any]
        #expect(nested?["url"] as? String == "https://x.com/?token=<redacted-secret>")
    }

    @Test func redactsValuesUnderSensitiveKeysRegardlessOfValueShape() {
        // A bare credential value need not match any standalone secret pattern;
        // the sensitive key name is the trust boundary.
        let input: [String: Any] = [
            "token": "abcdef0123456789plainvalue",
            "password": "p4ssw0rd",
            "api_key": "justletters",
            "Authorization": "Basic dXNlcjpwYXNz",
            "note": "/Users/alice/readme.txt",
            "count": 5,
        ]
        let output = scrubber.scrub(dictionary: input)
        #expect(output["token"] as? String == "<redacted-secret>")
        #expect(output["password"] as? String == "<redacted-secret>")
        #expect(output["api_key"] as? String == "<redacted-secret>")
        #expect(output["Authorization"] as? String == "<redacted-secret>")
        // Non-sensitive keys are still content-scrubbed and scalars pass through.
        #expect(output["note"] as? String == "/Users/<redacted>/readme.txt")
        #expect(output["count"] as? Int == 5)
    }

    @Test func redactsStructuredValuesUnderSensitiveKeys() {
        // The key is the trust boundary: an array or nested dict under a
        // sensitive key is dropped wholesale, not recursed into.
        let input: [String: Any] = [
            "cookie": ["session=abc", "csrf=def"],
            "credentials": ["user": "alice", "pass": "secret"] as [String: Any],
            "note": "plain",
        ]
        let output = scrubber.scrub(dictionary: input)
        #expect(output["cookie"] as? String == "<redacted-secret>")
        #expect(output["credentials"] as? String == "<redacted-secret>")
        #expect(output["note"] as? String == "plain")
    }

    @Test func sensitiveKeyMatchingIgnoresCaseAndSeparators() {
        #expect(SentryScrubber.isSensitiveKey("Access-Token"))
        #expect(SentryScrubber.isSensitiveKey("X_API_KEY"))
        #expect(SentryScrubber.isSensitiveKey("Cookie"))
        #expect(SentryScrubber.isSensitiveKey("session_id"))
        #expect(SentryScrubber.isSensitiveKey("authorization"))
        #expect(!SentryScrubber.isSensitiveKey("username"))
        #expect(!SentryScrubber.isSensitiveKey("count"))
        #expect(!SentryScrubber.isSensitiveKey("path"))
    }

    @Test func scrubsArraysOfStrings() {
        let value: Any = ["/Users/alice/x", "plain", "tok=secretsecretsecret123"]
        let output = scrubber.scrub(value: value) as? [Any]
        #expect(output?[0] as? String == "/Users/<redacted>/x")
        #expect(output?[1] as? String == "plain")
        // "tok" is not in the secret key set; token=/secret=/password= are.
        #expect(output?[2] as? String == "tok=secretsecretsecret123")
    }

    @Test func scrubOptionalNilPassesThrough() {
        #expect(scrubber.scrub(optional: nil) == nil)
        #expect(scrubber.scrub(optional: "/Users/lawrence/x") == "/Users/<redacted>/x")
    }

    @Test func combinedSecretEmailAndPathInOneString() {
        let input = "user lawrence@cmux.com opened /Users/lawrence/secret.txt with token=abcdef0123456789zz"
        #expect(
            scrubber.scrub(input)
                == "user <redacted-email> opened /Users/<redacted>/secret.txt with token=<redacted-secret>"
        )
    }
}
