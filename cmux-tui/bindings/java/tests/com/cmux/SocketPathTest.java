package com.cmux;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;

public final class SocketPathTest {
    private SocketPathTest() {}

    public static void main(String[] args) {
        runtimeRootPrefersXdgAndIgnoresEmptyValues();
        darwinBoundaryAccepts103BytesAndFallsBackAt104();
    }

    private static void runtimeRootPrefersXdgAndIgnoresEmptyValues() {
        assertEquals("/xdg-runtime", CmuxClient.runtimeBase("/xdg-runtime", "/tmp-runtime"));
        assertEquals("/tmp-runtime", CmuxClient.runtimeBase("", "/tmp-runtime"));
        assertEquals("/tmp", CmuxClient.runtimeBase("", ""));
    }

    private static void darwinBoundaryAccepts103BytesAndFallsBackAt104() {
        String base = "/tmp/runtime";
        String uid = "42";
        String emptySession = Path.of(base, "cmux-tui-" + uid, ".sock").toString();
        int sessionBytes = 103 - emptySession.getBytes(StandardCharsets.UTF_8).length;
        String session = "s".repeat(sessionBytes);

        String accepted = CmuxClient.defaultSocketPathFrom(base, uid, session, true);
        assertEquals(103, accepted.getBytes(StandardCharsets.UTF_8).length);
        if (!accepted.startsWith(base + "/")) {
            throw new AssertionError("accepted path did not use runtime base: " + accepted);
        }

        String fallback = CmuxClient.defaultSocketPathFrom(base, uid, session + "s", true);
        String prefix = Path.of("/tmp", "cmux-tui-" + uid).toString() + "/";
        if (!fallback.startsWith(prefix)) {
            throw new AssertionError("fallback path did not use private /tmp root: " + fallback);
        }
    }

    private static void assertEquals(Object expected, Object actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError("expected " + expected + ", got " + actual);
        }
    }
}
