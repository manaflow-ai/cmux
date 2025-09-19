import { SignUp, useUser } from "@stackframe/react";
import { useNavigate } from "@tanstack/react-router";
import { Form, Input, Modal, Typography } from "antd";
import { Cloud } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "./button";

const { Title, Paragraph } = Typography;

interface CloudModeWaitlistModalProps {
  visible: boolean;
  onClose: () => void;
  defaultEmail?: string;
  teamSlugOrId: string;
}

export function CloudModeWaitlistModal({
  visible,
  onClose,
  defaultEmail,
  teamSlugOrId,
}: CloudModeWaitlistModalProps) {
  const [form] = Form.useForm();
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState(false);
  const user = useUser({ or: "return-null" });
  const navigate = useNavigate();

  useEffect(() => {
    if (user) {
      return;
    }
    if (visible) {
      navigate({
        to: "/$teamSlugOrId",
        params: { teamSlugOrId },
        search: {
          after_auth_return_to: `/${teamSlugOrId}?waitlist=true`,
        },
        replace: true,
      });
    } else {
      navigate({
        to: "/$teamSlugOrId",
        params: { teamSlugOrId },
        replace: true,
      });
    }
  }, [visible, teamSlugOrId, navigate, user]);

  const handleSubmit = async (values: { email: string }) => {
    setLoading(true);
    try {
      // Save to Stack Auth client metadata
      if (user) {
        await user.update({
          clientMetadata: {
            ...user.clientMetadata,
            cloudModeWaitlist: true,
            cloudModeWaitlistEmail: values.email,
            cloudModeWaitlistDate: new Date().toISOString(),
          },
        });
      }

      navigate({
        to: "/$teamSlugOrId",
        params: { teamSlugOrId },
        replace: true,
      });

      // Show success state
      setSuccess(true);

      // Close after showing success message
      setTimeout(() => {
        onClose();
        form.resetFields();
        setSuccess(false);
      }, 2000);
    } catch (error) {
      console.error("Error joining waitlist:", error);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Modal
      open={visible}
      onCancel={!success ? onClose : undefined}
      footer={null}
      width={480}
      centered
      closable={!success}
    >
      <div className="flex flex-col items-center text-center py-4">
        {!user ? (
          <div className="w-full flex justify-center">
            <SignUp />
          </div>
        ) : success ? (
          <>
            <div className="flex items-center justify-center w-16 h-16 rounded-full bg-green-100 dark:bg-green-900/20 mb-4">
              <svg
                className="w-8 h-8 text-green-500"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
            </div>

            <Title level={3} className="!mb-2">
              You're on the list!
            </Title>

            <Paragraph className="text-neutral-500 dark:text-neutral-400">
              We'll email you when cloud mode is ready.
            </Paragraph>
          </>
        ) : (
          <>
            <div className="flex items-center justify-center w-16 h-16 rounded-full bg-blue-100 dark:bg-blue-900/20 mb-4">
              <Cloud className="w-8 h-8 text-blue-500" />
            </div>

            <Title level={3} className="!mb-2">
              Cloud Mode Coming Soon
            </Title>

            <Paragraph className="text-neutral-500 dark:text-neutral-400 mb-6">
              Cloud mode allows you to run cmux without local Docker setup. Join
              the waitlist to be notified when it's ready!
            </Paragraph>

            <Form
              form={form}
              onFinish={handleSubmit}
              className="w-full"
              initialValues={{ email: defaultEmail }}
            >
              <Form.Item
                name="email"
                rules={[
                  { required: true, message: "Please enter your email" },
                  { type: "email", message: "Please enter a valid email" },
                ]}
              >
                <Input
                  size="large"
                  placeholder="Enter your email"
                  className="!rounded-md"
                />
              </Form.Item>

              <div className="flex gap-2">
                <Button
                  type="button"
                  variant="outline"
                  className="flex-1"
                  onClick={onClose}
                >
                  Maybe Later
                </Button>
                <Button
                  type="submit"
                  variant="default"
                  className="flex-1"
                  disabled={loading}
                >
                  {loading ? "Joining..." : "Join Waitlist"}
                </Button>
              </div>
            </Form>
          </>
        )}
      </div>
    </Modal>
  );
}
