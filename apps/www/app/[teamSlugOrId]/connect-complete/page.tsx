import { OpenCmuxClient } from "../../desktop/after-sign-in/OpenCmuxClient";

export const dynamic = "force-dynamic";

export default function ConnectCompletePage({
  params,
}: {
  params: { teamSlugOrId: string };
}) {
  const href = `cmux://github-connect-complete?team=${encodeURIComponent(
    params.teamSlugOrId
  )}`;
  return <OpenCmuxClient href={href} />;
}
