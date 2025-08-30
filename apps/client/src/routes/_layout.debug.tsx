import { FloatingPane } from "@/components/floating-pane";
import { useSocket } from "@/contexts/socket/use-socket";
import { stackClientApp } from "@/stack";
import { useUser } from "@stackframe/react";
import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/_layout/debug")({
  component: DebugComponent,
});

function DebugComponent() {
  const { socket } = useSocket();
  const user = useUser({ or: "throw" });
  const githubConnectedAccount = user
    ? user.useConnectedAccount("github")
    : null;
  const accessToken = githubConnectedAccount?.useAccessToken();
  console.log(accessToken);

  return (
    <FloatingPane>
      <div className="p-4">
        <button
          onClick={async () => {
            const user = await stackClientApp.getUser();
            if (!user) {
              throw new Error("No user");
            }
            const authHeaders = await user.getAuthHeaders();
            fetch("http://localhost:9779/api/user", {
              headers: {
                ...authHeaders,
              },
            })
              .then((res) => res.text())
              .then((data) => console.log(data));
          }}
        >
          Get user
        </button>

        <br />

        <button
          onClick={() => {
            const teamSlugOrId =
              typeof window !== "undefined"
                ? window.location.pathname.split("/")[1] || "default"
                : "default";
            socket?.emit("github-fetch-repos", { teamSlugOrId }, (data) => {
              console.log(data);
            });
          }}
        >
          refetch github
        </button>

        <br />

        {/* <button
          onClick={async () => {
            const token = await githubConnectedAccount?.getAccessToken();
            console.log(token);
          }}
        >
          get github access token
        </button> */}
      </div>
    </FloatingPane>
  );
}
