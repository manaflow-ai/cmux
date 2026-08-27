package com.cmux.raw;

import com.cmux.raw.CloseWorkspaceRequest;
import com.cmux.raw.WorkspaceMutationResult;
import java.util.Objects;

/**
 * Owns a workspace created by {@link CmuxClient#createWorkspaceLease}.
 *
 * <p>Keep the creating client open until this lease closes. A successful close
 * is sent at most once; if closing fails, a later call may retry.
 */
public final class WorkspaceLease implements AutoCloseable {
    private final CmuxClient client;
    private final WorkspaceMutationResult creation;
    private volatile boolean closed;

    WorkspaceLease(CmuxClient client, WorkspaceMutationResult creation) {
        this.client = Objects.requireNonNull(client, "client");
        this.creation = Objects.requireNonNull(creation, "creation");
    }

    public WorkspaceMutationResult creation() {
        return creation;
    }

    public UInt64 workspace() {
        return creation.workspace();
    }

    public String key() {
        return creation.key();
    }

    public boolean isClosed() {
        return closed;
    }

    /**
     * Closes the owned workspace. Calls after the first successful close are no-ops.
     */
    @Override
    public synchronized void close() throws CmuxException {
        if (closed) {
            return;
        }
        client.closeWorkspace(
            CloseWorkspaceRequest.builder()
                .workspace(creation.workspace())
                .build()
        );
        closed = true;
    }
}
