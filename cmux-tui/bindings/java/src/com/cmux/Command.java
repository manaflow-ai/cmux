package com.cmux;

import java.util.Map;

public sealed interface Command permits ExactCommand, ShellCommand {
    Map<String, Object> toWire();

    static ExactCommand explicitShell(String executable, String script) {
        return ExactCommand.of(executable, "-lc", script);
    }
}
