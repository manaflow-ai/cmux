import { cookies } from "next/headers";
import { env } from "@/lib/utils/www-env";
import { OpenCmuxClient } from "./OpenCmuxClient";

export const dynamic = "force-dynamic";

export default async function AfterSignInPage() {
  const stackCookies = await cookies();
  const stackRefreshToken = stackCookies.get(`stack-refresh-${env.NEXT_PUBLIC_STACK_PROJECT_ID}`)?.value;
  const stackAccessToken = stackCookies.get(`stack-access`)?.value;

  if (stackRefreshToken && stackAccessToken) {
    const target = `cmux://auth-callback?stack_refresh=${encodeURIComponent(stackRefreshToken)}&stack_access=${encodeURIComponent(stackAccessToken)}`;
    return <OpenCmuxClient href={target} />;
  }

  return null;
}
