import { Button } from "@/components/ui/button";
import * as Dialog from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import {
  type FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";
import { z } from "zod";

export interface CreateTeamFormValues {
  displayName: string;
  slug: string;
  inviteEmails: string[];
}

interface CreateTeamDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSubmit: (values: CreateTeamFormValues) => Promise<void>;
}

function slugify(input: string): string {
  return input
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+/, "")
    .replace(/-+$/, "")
    .slice(0, 48);
}

function normalizeSlugInput(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+/, "")
    .replace(/-+$/, "")
    .slice(0, 48);
}

function parseInviteInput(value: string): string[] {
  if (!value.trim()) return [];
  const parts = value.split(/[\s,;]+/g);
  const seen = new Set<string>();
  const emails: string[] = [];
  for (const part of parts) {
    const email = part.trim();
    if (!email) continue;
    const lower = email.toLowerCase();
    if (seen.has(lower)) continue;
    seen.add(lower);
    emails.push(email);
  }
  return emails;
}

export function CreateTeamDialog({
  open,
  onOpenChange,
  onSubmit,
}: CreateTeamDialogProps) {
  const [displayName, setDisplayName] = useState("");
  const [slug, setSlug] = useState("");
  const [inviteInput, setInviteInput] = useState("");
  const [slugEdited, setSlugEdited] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  useEffect(() => {
    if (!open) {
      setDisplayName("");
      setSlug("");
      setInviteInput("");
      setSlugEdited(false);
      setError(null);
      setIsSubmitting(false);
    }
  }, [open]);

  const slugHint = useMemo(() => {
    if (!slug) return "";
    return `Team URL: /${slug}/…`;
  }, [slug]);

  const handleNameChange = useCallback(
    (value: string) => {
      setDisplayName(value);
      if (!slugEdited) {
        const auto = slugify(value);
        setSlug(auto);
      }
    },
    [slugEdited]
  );

  const handleSlugChange = useCallback((value: string) => {
    setSlugEdited(true);
    setSlug(normalizeSlugInput(value));
  }, []);

  const handleSubmit = useCallback(
    async (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      if (isSubmitting) {
        return;
      }
      setError(null);

      const trimmedName = displayName.trim();
      const normalizedSlug = normalizeSlugInput(slug);
      if (trimmedName.length === 0) {
        setError("Team name is required");
        return;
      }
      if (trimmedName.length > 64) {
        setError("Team name must be 1–64 characters long");
        return;
      }
      if (normalizedSlug.length < 3 || normalizedSlug.length > 48) {
        setError("Slug must be 3–48 characters long");
        return;
      }
      if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(normalizedSlug)) {
        setError(
          "Slug can contain lowercase letters, numbers, and hyphens, and must start/end with a letter or number"
        );
        return;
      }

      const inviteEmails = parseInviteInput(inviteInput);
      for (const email of inviteEmails) {
        const result = z.email().safeParse(email);
        if (!result.success) {
          setError(`Invalid invite email: ${email}`);
          return;
        }
      }

      setIsSubmitting(true);
      try {
        await onSubmit({
          displayName: trimmedName,
          slug: normalizedSlug,
          inviteEmails,
        });
        onOpenChange(false);
      } catch (err) {
        const message =
          typeof err === "string"
            ? err
            : err instanceof Error
              ? err.message
              : err &&
                  typeof err === "object" &&
                  "message" in err &&
                  typeof (err as { message?: unknown }).message === "string"
                ? (err as { message: string }).message
                : "Failed to create team";
        setError(message);
      } finally {
        setIsSubmitting(false);
      }
    },
    [displayName, inviteInput, isSubmitting, onOpenChange, onSubmit, slug]
  );

  const handleOpenChange = useCallback(
    (nextOpen: boolean) => {
      if (!nextOpen && isSubmitting) {
        return;
      }
      onOpenChange(nextOpen);
    },
    [isSubmitting, onOpenChange]
  );

  return (
    <Dialog.Root open={open} onOpenChange={handleOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-neutral-950/50 backdrop-blur-sm" />
        <Dialog.Content className="fixed left-1/2 top-1/2 w-full max-w-lg -translate-x-1/2 -translate-y-1/2 rounded-2xl border border-neutral-200 bg-white p-6 shadow-xl focus:outline-none dark:border-neutral-800 dark:bg-neutral-900">
          <div className="flex items-start justify-between gap-4">
            <div>
              <Dialog.Title className="text-lg font-semibold text-neutral-900 dark:text-neutral-50">
                Create a team
              </Dialog.Title>
              <Dialog.Description className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
                Give your team a name and a unique slug. You can invite
                teammates now or later.
              </Dialog.Description>
            </div>
            <Dialog.Close asChild>
              <button
                type="button"
                className="rounded-full p-2 text-neutral-500 transition hover:bg-neutral-100 hover:text-neutral-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-200"
                disabled={isSubmitting}
                aria-label="Close"
              >
                <X className="h-4 w-4" />
              </button>
            </Dialog.Close>
          </div>

          <form className="mt-6 space-y-5" onSubmit={handleSubmit}>
            <div className="space-y-2">
              <label
                className="text-sm font-medium text-neutral-800 dark:text-neutral-200"
                htmlFor="team-name"
              >
                Team name
              </label>
              <input
                id="team-name"
                type="text"
                value={displayName}
                onChange={(event) => handleNameChange(event.target.value)}
                placeholder="Acme Inc."
                className="w-full rounded-md border border-neutral-200 bg-white px-3 py-2 text-sm text-neutral-900 shadow-xs transition focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100"
                autoFocus
                disabled={isSubmitting}
              />
            </div>

            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <label
                  className="text-sm font-medium text-neutral-800 dark:text-neutral-200"
                  htmlFor="team-slug"
                >
                  Team slug
                </label>
                {slugHint ? (
                  <span className="text-xs text-neutral-500 dark:text-neutral-400">
                    {slugHint}
                  </span>
                ) : null}
              </div>
              <input
                id="team-slug"
                type="text"
                value={slug}
                onChange={(event) => handleSlugChange(event.target.value)}
                placeholder="acme"
                className="w-full rounded-md border border-neutral-200 bg-white px-3 py-2 text-sm text-neutral-900 shadow-xs transition focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100"
                disabled={isSubmitting}
              />
              <p className="text-xs text-neutral-500 dark:text-neutral-400">
                Lowercase letters, numbers, and hyphens. This appears in the
                URL.
              </p>
            </div>

            <div className="space-y-2">
              <label
                className="text-sm font-medium text-neutral-800 dark:text-neutral-200"
                htmlFor="team-invites"
              >
                Invite teammates (optional)
              </label>
              <textarea
                id="team-invites"
                value={inviteInput}
                onChange={(event) => setInviteInput(event.target.value)}
                placeholder="alice@example.com, bob@example.com"
                rows={3}
                className="w-full rounded-md border border-neutral-200 bg-white px-3 py-2 text-sm text-neutral-900 shadow-xs transition focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100"
                disabled={isSubmitting}
              />
              <p className="text-xs text-neutral-500 dark:text-neutral-400">
                Separate emails with spaces, commas, or new lines.
              </p>
            </div>

            {error ? (
              <div className="rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive dark:border-red-900/60 dark:bg-red-900/20">
                {error}
              </div>
            ) : null}

            <div className="flex items-center justify-end gap-3 pt-2">
              <Dialog.Close asChild>
                <Button
                  type="button"
                  variant="ghost"
                  className="text-neutral-600 hover:text-neutral-900 dark:text-neutral-300 dark:hover:text-neutral-50"
                  disabled={isSubmitting}
                >
                  Cancel
                </Button>
              </Dialog.Close>
              <Button type="submit" disabled={isSubmitting}>
                {isSubmitting ? "Creating…" : "Create team"}
              </Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
