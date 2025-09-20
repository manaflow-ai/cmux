import { normalizeOrigin } from "@cmux/shared";
import { env } from "@/client-env";

export const WWW_ORIGIN = normalizeOrigin(env.NEXT_PUBLIC_WWW_ORIGIN);
