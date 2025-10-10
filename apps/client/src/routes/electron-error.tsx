import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

const errorSearchSchema = z.object({
  type: z.enum(["navigation", "http"]),
  url: z.string().optional(),
  // Navigation error fields
  code: z.coerce.number().optional(),
  description: z.string().optional(),
  // HTTP error fields
  statusCode: z.coerce.number().optional(),
  statusText: z.string().optional(),
});

export const Route = createFileRoute("/electron-error")({
  validateSearch: errorSearchSchema,
  component: ElectronErrorPage,
});

interface ErrorDisplay {
  title: string;
  description: string;
  badgeLabel: string;
  details: Array<{ label: string; value: string }>;
}

type NavigationMatch = {
  test: RegExp;
  title: string;
  description: string;
};

const NAVIGATION_ERROR_MAPPINGS: NavigationMatch[] = [
  {
    test: /ERR_NAME_NOT_RESOLVED/i,
    title: "Domain not found",
    description:
      "The domain name couldn't be resolved. Verify the hostname or update your DNS settings.",
  },
  {
    test: /ERR_CONNECTION_REFUSED/i,
    title: "Connection refused",
    description:
      "The server refused the connection. Make sure the service is running and accepting connections.",
  },
  {
    test: /ERR_CONNECTION_TIMED_OUT/i,
    title: "Connection timed out",
    description:
      "The server took too long to respond. Check the server status or network connectivity.",
  },
  {
    test: /ERR_INTERNET_DISCONNECTED/i,
    title: "No internet connection",
    description:
      "We couldn't reach the internet. Check your network connection and try again.",
  },
  {
    test: /ERR_SSL_PROTOCOL_ERROR|ERR_CERT/i,
    title: "Secure connection failed",
    description:
      "The secure connection could not be established. Verify the TLS certificate or try HTTP.",
  },
  {
    test: /ERR_ADDRESS_UNREACHABLE|ERR_CONNECTION_RESET/i,
    title: "Host unreachable",
    description:
      "We couldn't reach the host. Confirm the service address and network routes.",
  },
];

function describeNavigationError(
  code: number,
  description: string,
  url: string,
): ErrorDisplay {
  const match = NAVIGATION_ERROR_MAPPINGS.find(({ test }) =>
    test.test(description),
  );

  const title = match?.title ?? "Failed to load page";
  const desc =
    match?.description ??
    "Something went wrong while loading this page. Try refreshing or check the network logs.";

  const badgeLabel = `Code ${code}`;

  const details: Array<{ label: string; value: string }> = [
    { label: "Error", value: description || `Code ${code}` },
    { label: "URL", value: url },
  ];

  return {
    title,
    description: desc,
    badgeLabel,
    details,
  };
}

function describeHttpError(
  statusCode: number,
  statusText: string | undefined,
  url: string,
): ErrorDisplay {
  let title = "Request failed";
  let description =
    "The server responded with an error. Try refreshing the page or checking the service logs.";

  if (statusCode === 404) {
    title = "Page not found";
    description =
      "We couldn't find that page. Double-check the URL or make sure the route is available.";
  } else if (statusCode === 401 || statusCode === 403) {
    title = "Access denied";
    description =
      "This page requires authentication or additional permissions. Sign in or update the request headers.";
  } else if (statusCode >= 500) {
    title = "Server error";
    description =
      "The server encountered an error while handling the request. Check the service logs or try again.";
  } else if (statusCode >= 400) {
    title = "Request blocked";
    description =
      "The server rejected the request. Review the request payload or try again.";
  }

  const statusDetail = statusText
    ? `HTTP ${statusCode} · ${statusText}`
    : `HTTP ${statusCode}`;

  return {
    title,
    description,
    badgeLabel: statusDetail,
    details: [
      { label: "Status", value: statusDetail },
      { label: "URL", value: url },
    ],
  };
}

function ElectronErrorPage() {
  const params = Route.useSearch() as z.infer<typeof errorSearchSchema>;

  const errorDisplay: ErrorDisplay =
    params.type === "http"
      ? describeHttpError(
          params.statusCode ?? 0,
          params.statusText,
          params.url ?? "",
        )
      : describeNavigationError(
          params.code ?? 0,
          params.description ?? "",
          params.url ?? "",
        );

  return (
    <div className="flex min-h-screen items-center justify-center bg-white p-6 dark:bg-neutral-950">
      <div className="w-full max-w-sm rounded-lg border border-neutral-200 bg-white p-6 shadow-lg ring-1 ring-neutral-900/5 dark:border-neutral-800 dark:bg-neutral-900 dark:ring-neutral-100/10">
        {errorDisplay.badgeLabel ? (
          <span className="mb-3 inline-flex items-center rounded-full bg-neutral-200 px-2.5 py-0.5 text-xs font-medium text-neutral-700 dark:bg-neutral-800 dark:text-neutral-300">
            {errorDisplay.badgeLabel}
          </span>
        ) : null}
        <h1 className="text-lg font-semibold text-neutral-900 dark:text-neutral-50">
          {errorDisplay.title}
        </h1>
        <p className="mt-2 text-sm leading-relaxed text-neutral-600 dark:text-neutral-300">
          {errorDisplay.description}
        </p>
        {errorDisplay.details.length > 0 ? (
          <dl className="mt-4 space-y-2 text-xs text-neutral-500 dark:text-neutral-400">
            {errorDisplay.details.map(({ label, value }) => (
              <div key={`${label}-${value}`}>
                <dt className="font-medium uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
                  {label}
                </dt>
                <dd className="mt-0.5 break-words text-neutral-600 dark:text-neutral-300">
                  {value}
                </dd>
              </div>
            ))}
          </dl>
        ) : null}
      </div>
    </div>
  );
}
