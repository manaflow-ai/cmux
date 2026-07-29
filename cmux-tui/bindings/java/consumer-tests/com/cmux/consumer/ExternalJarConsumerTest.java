package com.cmux.consumer;

import com.cmux.Client;
import com.cmux.CreatedTerminalPath;
import com.cmux.ExactCommand;
import com.cmux.MutationOutcomeUncertain;
import com.cmux.MutationResult;
import com.cmux.Results;
import com.cmux.ResourceStream;
import com.cmux.Session;
import com.cmux.Transport;
import com.cmux.Workspace;
import com.cmux.raw.CmuxClient;
import com.cmux.raw.RenderText;
import com.cmux.raw.UInt64;
import com.cmux.raw.WorkspaceLease;
import com.cmux.raw.CreateWorkspaceRequest;
import com.cmux.raw.RenderRow;
import com.cmux.raw.RenderRun;
import java.time.Duration;
import java.util.List;

public final class ExternalJarConsumerTest {
    private ExternalJarConsumerTest() {}

    public static void main(String[] args) throws ReflectiveOperationException {
        RenderRun run = RenderRun.builder()
            .attrs(0)
            .bg(null)
            .fg(null)
            .text("jar consumer")
            .build();
        RenderRow row = RenderRow.builder().row(0).runs(List.of(run)).build();
        require("jar consumer".equals(RenderText.plainText(row)), "render helper from jar");
        require(
            CmuxClient.MAX_SCROLLBACK_PAGE_ROWS == 65_535,
            "scrollback page bound from jar"
        );
        CmuxClient.class.getMethod("readScrollbackTail", UInt64.class, int.class);
        CmuxClient.class.getMethod(
            "createWorkspaceLease",
            CreateWorkspaceRequest.class
        );
        require(
            AutoCloseable.class.isAssignableFrom(WorkspaceLease.class),
            "workspace lease is closeable"
        );
        require(
            AutoCloseable.class.isAssignableFrom(Client.class),
            "resource client is closeable"
        );
        require(
            AutoCloseable.class.isAssignableFrom(ResourceStream.class),
            "resource stream is closeable"
        );
        require(
            !AutoCloseable.class.isAssignableFrom(Session.class),
            "resource handles are not closeable"
        );
        require(
            Transport.class.isInterface(),
            "resource transport can be injected"
        );
        require(
            ExactCommand.of("printf", "%s", "hello").argv().size() == 3,
            "exact argv is public from the jar"
        );
        Workspace.class.getMethod("run", com.cmux.Options.Run.class);
        MutationResult.class.getMethod("value");
        CreatedTerminalPath.class.getMethod("terminalId");
        Results.TerminalScreenResult.class.getMethod("text");
        Results.CreationResolution.class.getMethod("state");
        Results.TerminalWaitExitResult.class.getMethod("revision");
        Session.class.getMethod(
            "resolveCreation",
            com.cmux.Options.CreationResolve.class
        );
        ResourceStream.class.getMethod("poll", Duration.class);
        MutationOutcomeUncertain.class.getMethod("operation");
        MutationOutcomeUncertain.class.getMethod("idempotencyKey");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
